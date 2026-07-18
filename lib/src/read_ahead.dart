import 'dart:math';

import 'constants.dart';

/// Tracks sequential access patterns and recommends prefetch ranges.
///
/// When consecutive page-aligned reads are detected, the strategy expands
/// the fetch range beyond what's immediately needed — reducing the number
/// of HTTP round-trips for sequential scans (table scans, index walks).
///
/// Growth is exponential: after the threshold is reached, prefetch 1 page
/// ahead, then 2, 4, 8... up to [maxReadAheadPages].
class ReadAheadStrategy {
  /// Maximum number of extra pages to read ahead.
  final int maxReadAheadPages;

  /// Page size for alignment calculations.
  final int pageSize;

  /// File offset of the last read (for sequential detection).
  int _lastOffset = -1;

  /// Length of the last read.
  int _lastLength = 0;

  /// Count of consecutive sequential reads.
  int _sequentialHits = 0;

  /// The end byte of the last planned range.
  int _lastPlanEnd = -1;

  ReadAheadStrategy({
    this.maxReadAheadPages = defaultMaxReadAheadPages,
    required this.pageSize,
  });

  /// Number of consecutive sequential reads detected (for diagnostics).
  int get sequentialHits => _sequentialHits;

  /// Plan the actual fetch range for a read at [offset] of [length] bytes,
  /// given the total [fileSize].
  ///
  /// Returns a record with `fetchStart` and `fetchEnd` (inclusive byte range).
  /// When sequential access is detected, `fetchEnd` extends beyond the
  /// requested range to prefetch upcoming pages.
  ({int fetchStart, int fetchEnd}) plan(int offset, int length, int fileSize) {
    if (offset == _lastOffset && length == _lastLength) {
      // This is a retry of the exact same read after a cache miss/abort.
      // Do not update state, just return the previously calculated planned range.
      final fetchStart = (offset ~/ pageSize) * pageSize;
      final lastByteNeeded = offset + length - 1;
      final lastPageStart = (lastByteNeeded ~/ pageSize) * pageSize;
      var fetchEnd = lastPageStart + pageSize - 1;

      if (_sequentialHits >= readAheadThreshold) {
        final extraPages = min(
          maxReadAheadPages,
          1 << (_sequentialHits - readAheadThreshold),
        );
        fetchEnd = fetchEnd + (extraPages * pageSize);
      }
      if (fetchEnd >= fileSize) {
        fetchEnd = fileSize - 1;
      }
      return (fetchStart: fetchStart, fetchEnd: fetchEnd);
    }

    // Detect sequential access: current read starts where last read ended OR
    // where the last planned read-ahead range ended.
    final expectedNextFromLastRead = _lastOffset + _lastLength;
    final expectedNextFromLastPlan = _lastPlanEnd + 1;

    final isSequential = (_lastOffset >= 0 && offset == expectedNextFromLastRead) ||
        (_lastPlanEnd >= 0 && offset == expectedNextFromLastPlan);

    if (isSequential) {
      _sequentialHits++;
    } else {
      _sequentialHits = 0;
    }

    _lastOffset = offset;
    _lastLength = length;

    // Align start to page boundary
    final fetchStart = (offset ~/ pageSize) * pageSize;

    // Base end: at least cover the full page(s) spanned by the requested range.
    // This ensures putBulk always stores full pages (except possibly the last
    // page of the file).
    final lastByteNeeded = offset + length - 1;
    final lastPageStart = (lastByteNeeded ~/ pageSize) * pageSize;
    var fetchEnd = lastPageStart + pageSize - 1; // end of last full page

    // If sequential, expand the range with additional pages
    if (_sequentialHits >= readAheadThreshold) {
      final extraPages = min(
        maxReadAheadPages,
        1 << (_sequentialHits - readAheadThreshold), // 1, 2, 4, 8...
      );
      fetchEnd = fetchEnd + (extraPages * pageSize);
    }

    // Clamp to file size
    if (fetchEnd >= fileSize) {
      fetchEnd = fileSize - 1;
    }

    _lastPlanEnd = fetchEnd;
    return (fetchStart: fetchStart, fetchEnd: fetchEnd);
  }

  /// Reset sequential tracking (e.g. on file close or reopen).
  void reset() {
    _lastOffset = -1;
    _lastLength = 0;
    _sequentialHits = 0;
    _lastPlanEnd = -1;
  }
}
