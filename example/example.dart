/// Example: Query a remote SQLite database via HTTP range requests.
///
/// Usage:
///   dart run example/example.dart http://localhost:8080/catalog.db
///
/// The server must support HTTP Range requests (206 Partial Content).
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run example/example.dart <url>');
    stderr.writeln('  e.g. dart run example/example.dart http://localhost:8080/catalog.db');
    exit(1);
  }

  final url = args[0];

  // Register the HTTP VFS. SocketFetcher is used for http:// URLs,
  // CurlFetcher for https:// (requires curl on the system).
  final vfs = HttpVfs(
    pageSize: 4096, // must match the remote DB's PRAGMA page_size
    maxCachePages: 256, // cache up to 1 MB of pages
  );
  sqlite3.registerVirtualFileSystem(vfs);

  // Open the remote database — only the header is fetched at this point.
  final db = sqlite3.open(url, vfs: 'httpvfs', mode: OpenMode.readOnly);

  // Run queries. Each query fetches only the pages it needs.
  final tables = db.select(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
  );
  print('Tables:');
  for (final row in tables) {
    print('  ${row['name']}');
  }

  db.dispose();
}
