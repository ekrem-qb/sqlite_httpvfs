import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
import 'package:sqlite_httpvfs/src/http_vfs_config.dart';
import 'package:test/test.dart';

import 'test_server.dart';

void main() {
  late String tempDbPath;
  late Directory chunkedDir;
  late TestServer server;

  setUpAll(() {
    // 1. Create a test SQLite database on disk
    final tempDir = Directory.systemTemp.createTempSync('httpvfs_latency_');
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

    // Insert enough test data to span multiple chunks (at least 48KB of DB)
    final stmt = db.prepare(
      'INSERT INTO content (title, description, year, rating) VALUES (?, ?, ?, ?)',
    );
    for (var i = 1; i <= 150; i++) {
      stmt.execute([
        'Movie $i',
        'Description for movie $i with some extra text to fill the page and guarantee chunk transitions '
            'across multiple pages and chunks on the remote HTTP file server.',
        2000 + (i % 25),
        (i % 50) / 5.0,
      ]);
    }
    stmt.dispose();

    db.execute('VACUUM');
    db.close();

    // 2. Split the database into chunks
    chunkedDir =
        Directory.systemTemp.createTempSync('httpvfs_latency_chunked_');

    final dbBytes = File(tempDbPath).readAsBytesSync();
    final dbLength = dbBytes.length;
    const serverChunkSize = 16384; // 16KB chunks

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
      "suffixLength": 4,
    }
    ''';
    File('${chunkedDir.path}/config.json').writeAsStringSync(configJson);
  });

  tearDownAll(() {
    try {
      File(tempDbPath).parent.deleteSync(recursive: true);
      chunkedDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Chunked Parallelization Latency Test', () {
    setUp(() async {
      server = await TestServer.startWithDirectory(chunkedDir.path);
    });

    tearDown(() async {
      await server.stop();
    });

    test(
        'verifies concurrent chunk fetches execute in parallel under simulated latency',
        () async {
      final vfsName = 'httpvfs-latency';

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
          urlPrefix: '${server.url}db.sqlite3.',
          suffixLength: 4,
          // Injecting a 100ms delay to each request on the test server
          cacheBust: '1&delay=100',
        ),
        configUri: Uri.parse(server.url),
      );

      final db = await DatabaseAsyncWrapper.open(
        'any_name',
        vfs: vfs,
        vfsName: vfsName,
        mode: OpenMode.readOnly,
      );

      try {
        // Warm up: fetch the first page/header to initialize sqlite connections and caches
        final warmUpResults =
            await db.select('SELECT title FROM content LIMIT 80');
        expect(warmUpResults.length, 80);

        // Verify page size is 4096
        final pageSizeResult = await db.select('PRAGMA page_size');
        expect(pageSizeResult.first.values.first, 4096);

        // Time a large sequential query that triggers read-ahead across multiple chunks
        // We read a large range of IDs sequentially. This requires loading several pages,
        // which will trigger the read-ahead strategy to fetch up to maxReadAheadPages (8 pages = 32KB).
        // Since chunks are 16KB, a 32KB read spans at least 2 and likely 3 chunks.
        final stopwatch = Stopwatch()..start();
        final results = await db.select(
          "SELECT COUNT(*) as cnt FROM content WHERE title LIKE '%Movie%'",
        );
        stopwatch.stop();

        // The count should be correct
        expect(results.first['cnt'], 150);

        // Log the duration of the query
        final durationMs = stopwatch.elapsedMilliseconds;
        print('Query took $durationMs ms to execute.');

        // Under sequential execution:
        // fetching 3 chunks sequentially takes 3 * 100ms = 300ms.
        // Under parallel execution:
        // fetching 3 chunks in parallel takes 1 * 100ms = 100ms.
        // We assert that the total duration is significantly less than 150ms to prove parallelization.
        expect(durationMs, lessThan(150),
            reason:
                'Expected parallel chunk requests to complete in < 150ms, but took $durationMs ms (sequential fallback).');
      } finally {
        db.close();
      }
    });
  });
}
