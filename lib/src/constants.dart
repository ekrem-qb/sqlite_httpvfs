/// Default SQLite page size in bytes.
///
/// Must match the remote database's `PRAGMA page_size`. Common values:
/// 1024 (compact), 4096 (default), 8192, 16384, 32768, 65536.
const int defaultPageSize = 4096;

/// Default maximum number of pages to keep in the LRU cache.
///
/// With [defaultPageSize] of 4096, 256 pages = 1 MB of cached data.
const int defaultMaxCachePages = 256;

/// Default maximum read-ahead pages when sequential access is detected.
const int defaultMaxReadAheadPages = 8;

/// Number of consecutive sequential reads before read-ahead kicks in.
const int readAheadThreshold = 2;

/// Default timeout for HTTP requests in seconds.
const int defaultTimeoutSeconds = 30;
