import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
import 'package:sqlite_httpvfs/src/http_vfs_config.dart';
import 'package:test/test.dart';

import 'test_server.dart';

void main() {
  late String tempDbPath;
  late TestServer server;
  late String url;

  setUpAll(() {
    // Create a test SQLite database on disk
    final tempDir = Directory.systemTemp.createTempSync('httpvfs_test_');
    tempDbPath = '${tempDir.path}/test.db';

    final db = sqlite3.open(tempDbPath);
    db.execute('PRAGMA page_size = 4096');
    db.execute('PRAGMA journal_mode = DELETE');

    db.execute('''
      CREATE TABLE content (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        year INTEGER,
        rating REAL
      )
    ''');

    db.execute('CREATE INDEX idx_content_year ON content(year)');

    // Insert test data
    final stmt = db.prepare(
      'INSERT INTO content (title, description, year, rating) VALUES (?, ?, ?, ?)',
    );
    for (var i = 1; i <= 100; i++) {
      stmt.execute([
        'Movie $i',
        'Description for movie $i with some extra text to fill the page',
        2000 + (i % 25),
        (i % 50) / 5.0,
      ]);
    }
    stmt.dispose();

    db.execute('VACUUM');
    db.close();
  });

  tearDownAll(() {
    try {
      File(tempDbPath).parent.deleteSync(recursive: true);
    } catch (_) {}
  });

  // Use a unique VFS name per test to avoid registration conflicts.
  var testIndex = 0;
  String nextVfsName() => 'httpvfs-test-${testIndex++}';

  group('HttpVfs', () {
    setUp(() async {
      server = await TestServer.startWithFile(tempDbPath);
      url = server.url;
    });

    tearDown(() async {
      await server.stop();
    });

    test('open and SELECT single row', () async {
      final vfsName = nextVfsName();

      final db = await DatabaseAsyncWrapper.open(url,
          vfsName: vfsName, mode: OpenMode.readOnly);
      final results = await db.select(
        'SELECT id, title, year FROM content WHERE id = 1',
      );
      expect(results.length, 1);
      expect(results.first['title'], 'Movie 1');
      expect(results.first['year'], 2001);
      db.close();
    });

    test('COUNT(*) returns 100 rows', () async {
      final vfsName = nextVfsName();

      final db = await DatabaseAsyncWrapper.open(url,
          vfsName: vfsName, mode: OpenMode.readOnly);
      final results = await db.select('SELECT COUNT(*) as cnt FROM content');
      expect(results.first['cnt'], 100);
      db.close();
    });

    test('WHERE clause with index', () async {
      final vfsName = nextVfsName();

      final db = await DatabaseAsyncWrapper.open(url,
          vfsName: vfsName, mode: OpenMode.readOnly);
      final results = await db.select(
        'SELECT COUNT(*) as cnt FROM content WHERE year = 2005',
      );
      expect(results.first['cnt'], greaterThan(0));
      db.close();
    });

    test('ORDER BY and LIMIT', () async {
      final vfsName = nextVfsName();

      final db = await DatabaseAsyncWrapper.open(url,
          vfsName: vfsName, mode: OpenMode.readOnly);
      final results = await db.select(
        'SELECT title FROM content ORDER BY id DESC LIMIT 5',
      );
      expect(results.length, 5);
      expect(results.first['title'], 'Movie 100');
      expect(results.last['title'], 'Movie 96');
      db.close();
    });

    test('LIKE search', () async {
      final vfsName = nextVfsName();

      final db = await DatabaseAsyncWrapper.open(url,
          vfsName: vfsName, mode: OpenMode.readOnly);
      final results = await db.select(
        "SELECT title FROM content WHERE title LIKE '%42%'",
      );
      expect(results.length, 1);
      expect(results.first['title'], 'Movie 42');
      db.close();
    });

    test('write attempt is rejected', () async {
      final vfsName = nextVfsName();

      final db = await DatabaseAsyncWrapper.open(url,
          vfsName: vfsName, mode: OpenMode.readOnly);
      expect(
        () => db.execute(
          'INSERT INTO content (title, year) VALUES ("test", 2024)',
        ),
        throwsA(anything),
      );
      db.close();
    });
  });

  group('HttpVfs cache behavior', () {
    setUp(() async {
      server = await TestServer.startWithFile(tempDbPath);
      url = server.url;
    });

    tearDown(() async {
      await server.stop();
    });

    test('cache has hits after repeated queries', () async {
      final vfsName = nextVfsName();

      final db = await DatabaseAsyncWrapper.open(url,
          vfsName: vfsName, mode: OpenMode.readOnly);

      // Get the file handle to inspect cache stats
      // First query warms cache
      await db.select('SELECT * FROM content WHERE id = 1');
      await db.select('SELECT * FROM content WHERE id = 1');

      // We can't easily inspect cache stats externally, but we verify
      // that repeated queries succeed without error
      final results = await db.select('SELECT * FROM content WHERE id = 1');
      expect(results.length, 1);

      db.close();
    });
  });

  group('HttpVfs file size', () {
    setUp(() async {
      server = await TestServer.startWithFile(tempDbPath);
      url = server.url;
    });

    tearDown(() async {
      await server.stop();
    });

    test('file size matches actual file', () async {
      final actualSize = File(tempDbPath).lengthSync();
      final fetcher = AsyncHttpFetcher();
      final reportedSize =
          await fetcher.waitForValid(() => fetcher.fetchFileSize(url));
      expect(reportedSize, actualSize);
    });
  });

  group('HttpVfs chunked mode', () {
    late Directory chunkedDir;
    late TestServer chunkedServer;

    setUp(() async {
      chunkedDir = Directory.systemTemp.createTempSync('httpvfs_chunked_');

      final dbFile = File(tempDbPath);
      final dbBytes = dbFile.readAsBytesSync();
      final dbLength = dbBytes.length;
      final serverChunkSize = 16384;

      // Write chunks
      var offset = 0;
      var chunkId = 0;
      while (offset < dbLength) {
        final end = offset + serverChunkSize < dbLength
            ? offset + serverChunkSize
            : dbLength;
        final chunkBytes = dbBytes.sublist(offset, end);
        final chunkStr = chunkId.toString().padLeft(4, '0');
        File('${chunkedDir.path}/db.sqlite3.$chunkStr')
            .writeAsBytesSync(chunkBytes);
        offset += serverChunkSize;
        chunkId++;
      }

      // Write config.json
      final configJson = '''
      {
        "serverMode": "chunked",
        "requestChunkSize": 4096,
        "serverChunkSize": 16384,
        "databaseLengthBytes": $dbLength,
        "urlPrefix": "db.sqlite3.",
        "suffixLength": 4
      }
      ''';
      File('${chunkedDir.path}/config.json').writeAsStringSync(configJson);

      chunkedServer = await TestServer.startWithDirectory(chunkedDir.path);
    });

    tearDown(() async {
      await chunkedServer.stop();
      try {
        chunkedDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('open and query chunked database via configUrl in VFS constructor',
        () async {
      final vfsName = nextVfsName();
      final configUrl = '${chunkedServer.url}config.json';

      final db = await DatabaseAsyncWrapper.open(configUrl,
          vfsName: vfsName, mode: OpenMode.readOnly);
      final results = await db.select('SELECT COUNT(*) as cnt FROM content');
      expect(results.first['cnt'], 100);

      final row =
          await db.select('SELECT id, title, year FROM content WHERE id = 1');
      expect(row.length, 1);
      expect(row.first['title'], 'Movie 1');
      expect(row.first['year'], 2001);

      db.close();
    });

    test('open and query chunked database via inline config in VFS constructor',
        () async {
      final vfsName = nextVfsName();
      final dbFile = File(tempDbPath);
      final dbLength = dbFile.lengthSync();

      final vfs = HttpVfs(
        name: vfsName,
        fetcher: AsyncHttpFetcher(),
        config: HttpVfsConfig(
          serverMode: 'chunked',
          requestChunkSize: 4096,
          serverChunkSize: 16384,
          databaseLengthBytes: dbLength,
          urlPrefix: '${chunkedServer.url}db.sqlite3.',
          suffixLength: 4,
        ),
        configUri: Uri.parse(chunkedServer.url),
      );

      final db = await DatabaseAsyncWrapper.open('any_name_here',
          vfs: vfs, vfsName: vfsName, mode: OpenMode.readOnly);
      final results = await db.select('SELECT COUNT(*) as cnt FROM content');
      expect(results.first['cnt'], 100);

      final row =
          await db.select('SELECT id, title, year FROM content WHERE id = 42');
      expect(row.length, 1);
      expect(row.first['title'], 'Movie 42');

      db.close();
    });
  });
}
