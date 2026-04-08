import 'package:sqlite3/common.dart';

import 'constants.dart';
import 'fetcher.dart';
import 'http_vfs_file.dart';
import 'page_cache.dart';
import 'read_ahead.dart';

/// HTTP range-request VFS for SQLite.
///
/// Registers with the `sqlite3` library as a custom VFS. When SQLite reads
/// database pages, this VFS fetches them via HTTP Range requests and caches
/// them in memory. Write operations are rejected — this is read-only.
///
/// Usage:
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
/// ```
base class HttpVfs extends BaseVirtualFileSystem {
  /// Page size in bytes. Must match the remote database's `PRAGMA page_size`.
  final int pageSize;

  /// Maximum number of pages in the LRU cache per file handle.
  final int maxCachePages;

  /// Maximum read-ahead pages for sequential access patterns.
  final int maxReadAheadPages;

  /// Default HTTP headers to include in every request.
  final Map<String, String>? defaultHeaders;

  /// HTTP fetcher. If null, one is auto-created based on the URL scheme.
  final SyncHttpFetcher? fetcher;

  /// Optional URL resolver. Transforms the filename passed to `sqlite3.open()`
  /// into the actual HTTP URL to fetch. Defaults to identity (filename = URL).
  final String Function(String)? urlResolver;

  HttpVfs({
    String name = 'httpvfs',
    this.pageSize = defaultPageSize,
    this.maxCachePages = defaultMaxCachePages,
    this.maxReadAheadPages = defaultMaxReadAheadPages,
    this.defaultHeaders,
    this.fetcher,
    this.urlResolver,
  }) : super(name: name);

  @override
  XOpenResult xOpen(Sqlite3Filename path, int flags) {
    final rawPath = path.path ?? '';

    // Journal, WAL, and SHM files should appear empty for a read-only VFS
    if (_isAuxiliaryFile(rawPath)) {
      return (file: EmptyVfsFile(), outFlags: 0);
    }

    final url = urlResolver != null ? urlResolver!(rawPath) : rawPath;
    final httpFetcher = fetcher ?? createFetcher(url);

    // Get file size via HEAD request
    final fileSize = httpFetcher.fetchFileSize(url, headers: defaultHeaders);

    final cache = LruPageCache(maxPages: maxCachePages, pageSize: pageSize);
    final readAhead = ReadAheadStrategy(
      maxReadAheadPages: maxReadAheadPages,
      pageSize: pageSize,
    );

    final vfsFile = HttpVfsFile(
      url: url,
      fileSize: fileSize,
      fetcher: httpFetcher,
      cache: cache,
      readAhead: readAhead,
      headers: defaultHeaders,
    );

    return (
      file: vfsFile,
      outFlags: SqlFlag.SQLITE_OPEN_READONLY,
    );
  }

  @override
  void xDelete(String path, int syncDir) {
    // No-op: read-only VFS.
  }

  @override
  int xAccess(String path, int flags) {
    // Report auxiliary files as non-existent to prevent SQLite from trying
    // to open them.
    if (_isAuxiliaryFile(path)) return 0;
    return 1; // Main database "exists"
  }

  @override
  String xFullPathName(String path) => path;

  @override
  void xSleep(Duration duration) {
    // Minimal implementation — sqlite3 rarely calls this
    final ms = duration.inMilliseconds;
    if (ms > 0) {
      final end = DateTime.now().add(duration);
      while (DateTime.now().isBefore(end)) {
        // spin
      }
    }
  }

  /// Returns true if [path] is a SQLite auxiliary file (journal, WAL, SHM).
  bool _isAuxiliaryFile(String path) {
    return path.endsWith('-journal') ||
        path.endsWith('-wal') ||
        path.endsWith('-shm');
  }
}
