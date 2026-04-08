## 0.1.0

- Initial release.
- Implemented `HttpVfs` for the `sqlite3` Dart package.
- Added `SocketFetcher` for native HTTP support,cross platform.
- Added `CurlFetcher` for HTTPS support via external `curl` process, only unix.
- Implemented range-request lazy loading and in-memory page caching.
