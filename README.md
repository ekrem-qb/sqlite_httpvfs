# sqlite_httpvfs

HTTP range-request Virtual File System (VFS) for the [`sqlite3`](https://pub.dev/packages/sqlite3) Dart package.

Query remote SQLite databases by fetching only the pages needed via HTTP Range requests. This is the Dart equivalent of [`sql.js-httpvfs`](https://github.com/phiresky/sql.js-httpvfs), allowing you to query massive databases hosted on static servers (like S3, Cloudflare Pages, etc.) without downloading the entire file.

## Features

- **Lazy loading:** Only the exact database pages needed to resolve a query are fetched.
- **Configurable Caching:** Automatically caches pages in memory.
- **Custom Fetchers:** Built-in support for different fetch mechanisms depending on the environment and protocol (HTTP vs HTTPS).

## Fetchers

The package includes two built-in fetchers to handle HTTP requests:

- **`SocketFetcher`**: Uses Dart's native `Socket`. It only supports plain `http://` URLs.
- **`CurlFetcher`**: Executes the system's `curl` binary to perform requests. It supports both `http://` and `https://` URLs, making it necessary for securely hosted databases. It requires the environment to have `curl` installed and accessible in the system PATH.

By default, the VFS will attempt to pick the appropriate fetcher transparently based on the URL scheme, utilizing `CurlFetcher` for HTTPS.

## Usage

Add `sqlite_httpvfs` to your `pubspec.yaml` along with `sqlite3`.

```dart
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';

void main() {
  // Register the HTTP VFS.
  final vfs = HttpVfs(
    pageSize: 4096, // Must match the remote DB's PRAGMA page_size
    maxCachePages: 256, // Size of the in-memory page LRU cache
  );
  sqlite3.registerVirtualFileSystem(vfs);

  // Open the remote database (this fetches the header)
  final db = sqlite3.open(
    'http://localhost:8080/catalog.db',
    vfs: 'httpvfs',
    mode: OpenMode.readOnly
  );

  // Run queries. Uses Range requests to fetch only required chunks!
  final results = db.select('SELECT * FROM users LIMIT 10');
  for (final row in results) {
    print(row);
  }

  db.dispose();
}
```

## Requirements

1. The remote server hosting the database must accept `Range` HTTP headers and correctly return `206 Partial Content` responses. Standard static file hosting servers typically support this out of the box.
2. If querying an `https://` URL via the `CurlFetcher` on desktop/server, `curl` must be installed.
