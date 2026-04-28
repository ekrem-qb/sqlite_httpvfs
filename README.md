# sqlite_httpvfs

HTTP range-request Virtual File System (VFS) for the [`sqlite3`](https://pub.dev/packages/sqlite3) Dart package.

Query remote SQLite databases by fetching only the pages needed via HTTP Range requests. This is the Dart equivalent of [`sql.js-httpvfs`](https://github.com/phiresky/sql.js-httpvfs), allowing you to query massive databases hosted on static servers (like S3, Cloudflare Pages, etc.) without downloading the entire file.

## Features

- **Lazy loading:** Only the exact database pages needed to resolve a query are fetched.
- **Configurable Caching:** Automatically caches pages in memory.
- **Custom Fetchers:** Built-in support for different fetch mechanisms depending on the environment and protocol (HTTP vs HTTPS).

## Fetchers

SQLite's VFS `xRead` callback is **synchronous** — it can't `await`. Each fetcher in this package is a different strategy for doing synchronous HTTP from inside that callback.

| Fetcher           | Schemes        | Platforms                            | TLS              | Construction |
|-------------------|----------------|--------------------------------------|------------------|--------------|
| `SocketFetcher`   | `http://`      | iOS, Android, macOS, Linux, Windows  | —                | sync         |
| `IsolateFetcher`  | `http`/`https` | iOS, Android, macOS, Linux, Windows  | platform-native  | async (`create`) |
| `CurlFetcher`     | `http`/`https` | macOS, Linux, Windows (needs `curl`) | via curl/OpenSSL | sync         |

- **`SocketFetcher`** uses `RawSynchronousSocket` for a fully synchronous HTTP/1.1 request. Plain HTTP only — Dart has no synchronous TLS API. Best for local IPFS gateways, LAN servers, or anything plain-HTTP.
- **`IsolateFetcher`** spawns a worker isolate that hosts a loopback `ServerSocket` and a pooled `HttpClient`. The main isolate connects **once** via `RawSynchronousSocket` and reuses that connection for every read. The worker handles real HTTP/HTTPS asynchronously using `dart:io`'s `HttpClient`, so TLS uses each platform's native stack — no `curl` dependency, works on iOS and Android. Upstream connections are kept alive, so a sequence of range reads against the same host pays only one TLS handshake.
- **`CurlFetcher`** shells out to `curl` for each request. Simple but desktop-only and one process per request.

`createFetcher(url)` picks `SocketFetcher` for `http://` and `CurlFetcher` for `https://` synchronously. Prefer `await createFetcherAsync(url)` for HTTPS — it returns an `IsolateFetcher` that works on every platform and avoids the `curl` dependency.

## Usage

Add `sqlite_httpvfs` to your `pubspec.yaml` along with `sqlite3`.

### Plain HTTP

```dart
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';

void main() {
  final vfs = HttpVfs(
    pageSize: 4096,     // Must match the remote DB's PRAGMA page_size
    maxCachePages: 256, // In-memory page LRU cache
  );
  sqlite3.registerVirtualFileSystem(vfs);

  final db = sqlite3.open(
    'http://localhost:8080/catalog.db',
    vfs: 'httpvfs',
    mode: OpenMode.readOnly,
  );

  final results = db.select('SELECT * FROM users LIMIT 10');
  for (final row in results) print(row);

  db.dispose();
}
```

### HTTPS, cross-platform (recommended)

Use `IsolateFetcher` to get HTTPS support on every platform Dart runs on, including iOS and Android, without depending on `curl`:

```dart
Future<void> main() async {
  final fetcher = await IsolateFetcher.create();

  final vfs = HttpVfs(fetcher: fetcher);
  sqlite3.registerVirtualFileSystem(vfs);

  final db = sqlite3.open(
    'https://example.com/catalog.db',
    vfs: 'httpvfs',
    mode: OpenMode.readOnly,
  );

  final results = db.select('SELECT * FROM users LIMIT 10');
  for (final row in results) print(row);

  db.dispose();
  await fetcher.dispose(); // tears down the worker isolate
}
```

`IsolateFetcher` keeps a single loopback connection between the main isolate and its worker, and pools upstream connections inside the worker — so a query that touches many pages doesn't repeat the TLS handshake.

## Requirements

1. The remote server must accept `Range` HTTP headers and return `206 Partial Content`. Standard static file hosts (S3, CloudFront, Cloudflare R2, GitHub Pages, plain nginx/Apache) all support this.
2. `CurlFetcher` requires the `curl` binary on `PATH`. `IsolateFetcher` and `SocketFetcher` have no external dependencies.
