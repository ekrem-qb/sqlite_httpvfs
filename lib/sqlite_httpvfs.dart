/// HTTP range-request VFS for the sqlite3 Dart package.
///
/// Enables querying remote SQLite databases by fetching only the pages needed
/// via HTTP Range requests — the Dart equivalent of sql.js-httpvfs.
///
/// ```dart
/// import 'package:sqlite3/sqlite3.dart';
/// import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
///
/// final vfs = HttpVfs();
/// sqlite3.registerVirtualFileSystem(vfs);
///
/// final db = sqlite3.open(
///   'http://localhost:8080/catalog.db',
///   vfs: 'httpvfs',
///   mode: OpenMode.readOnly,
/// );
///
/// final results = db.select('SELECT * FROM content LIMIT 10');
/// ```
library;

export 'src/constants.dart';
export 'src/fetcher.dart';
export 'src/fetcher_curl.dart';
export 'src/fetcher_isolate.dart';
export 'src/fetcher_socket.dart';
export 'src/http_vfs.dart';
export 'src/http_vfs_file.dart';
export 'src/page_cache.dart';
export 'src/read_ahead.dart';
