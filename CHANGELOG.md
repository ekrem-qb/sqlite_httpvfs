## 0.2.0

- Added `IsolateFetcher`: synchronous HTTP/HTTPS fetcher that bridges sync ↔ async via a worker isolate. Cross-platform (iOS, Android, macOS, Linux, Windows) — uses `dart:io`'s `HttpClient` for platform-native TLS, no `curl` dependency.
- The main isolate keeps a single persistent `RawSynchronousSocket` to the worker; the worker pools a single `HttpClient` so successive range reads against the same host reuse the upstream TLS connection.
- Added `createFetcherAsync(url)` that returns `IsolateFetcher` for `https://` and `SocketFetcher` for `http://`.
- Test infrastructure now supports HTTPS (self-signed cert) so `IsolateFetcher` is exercised end-to-end over TLS, including bad-cert rejection.

## 0.1.0

- Initial release.
- Implemented `HttpVfs` for the `sqlite3` Dart package.
- Added `SocketFetcher` for native HTTP support, cross platform.
- Added `CurlFetcher` for HTTPS support via external `curl` process, only unix.
- Implemented range-request lazy loading and in-memory page caching.
