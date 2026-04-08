import 'dart:collection';
import 'dart:typed_data';

/// LRU (Least Recently Used) page cache for SQLite database pages.
///
/// Pages are keyed by their file offset (must be page-aligned). When the cache
/// exceeds [maxPages], the least recently accessed page is evicted.
///
/// Uses a [LinkedHashMap] with access-order iteration for O(1) LRU operations.
class LruPageCache {
  /// Maximum number of pages to keep in cache.
  final int maxPages;

  /// Page size in bytes. All pages are this size (except possibly the last page
  /// of the file, which may be shorter).
  final int pageSize;

  /// Internal storage: offset → page data. LinkedHashMap preserves insertion
  /// order; we remove and re-insert on access to maintain LRU ordering.
  final LinkedHashMap<int, Uint8List> _pages = LinkedHashMap<int, Uint8List>();

  /// Number of cache hits (for diagnostics).
  int hits = 0;

  /// Number of cache misses (for diagnostics).
  int misses = 0;

  LruPageCache({required this.maxPages, required this.pageSize});

  /// Number of pages currently cached.
  int get length => _pages.length;

  /// Total bytes currently cached.
  int get totalBytes {
    var total = 0;
    for (final page in _pages.values) {
      total += page.length;
    }
    return total;
  }

  /// Get a cached page by its file [offset], or null on miss.
  ///
  /// Refreshes the page's position in the LRU order (most recently used).
  Uint8List? get(int offset) {
    final page = _pages.remove(offset);
    if (page != null) {
      // Re-insert to mark as most recently used
      _pages[offset] = page;
      hits++;
      return page;
    }
    misses++;
    return null;
  }

  /// Check if a page at [offset] is cached (without affecting LRU order).
  bool containsPage(int offset) => _pages.containsKey(offset);

  /// Insert a single page at [offset]. Evicts LRU page if at capacity.
  void put(int offset, Uint8List data) {
    // Remove if already exists (will be re-inserted at end)
    _pages.remove(offset);
    _evictIfNeeded();
    _pages[offset] = data;
  }

  /// Insert a contiguous block of bytes starting at [startOffset].
  ///
  /// Splits [data] into page-sized chunks and caches each one. Handles
  /// partial trailing pages (last page of a file may be shorter).
  void putBulk(int startOffset, List<int> data) {
    var offset = startOffset;
    var pos = 0;

    while (pos < data.length) {
      final remaining = data.length - pos;
      final chunkSize = remaining < pageSize ? remaining : pageSize;

      final page = Uint8List(chunkSize);
      for (var i = 0; i < chunkSize; i++) {
        page[i] = data[pos + i];
      }

      put(offset, page);
      offset += pageSize;
      pos += chunkSize;
    }
  }

  /// Remove all cached pages and reset statistics.
  void clear() {
    _pages.clear();
    hits = 0;
    misses = 0;
  }

  void _evictIfNeeded() {
    while (_pages.length >= maxPages) {
      // Remove the first entry (least recently used)
      _pages.remove(_pages.keys.first);
    }
  }
}
