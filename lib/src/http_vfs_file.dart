import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite3/common.dart';
import 'package:sqlite_httpvfs/src/http_vfs_config.dart';

import 'fetcher.dart';
import 'page_cache.dart';
import 'read_ahead.dart';

/// A VFS file handle backed by HTTP range requests.
///
/// Implements [BaseVfsFile] so that `xRead` automatically handles short-read
/// zero-filling via the [readInto] method. All write operations are rejected
/// — this is a read-only VFS.
class HttpVfsFile extends BaseVfsFile {
  final String url;
  final int fileSize;
  final SyncHttpFetcher _fetcher;
  final LruPageCache _cache;
  final ReadAheadStrategy _readAhead;
  final Map<String, String>? _headers;
  final HttpVfsConfig? _config;

  /// Number of HTTP fetches performed (for diagnostics/testing).
  int fetchCount = 0;

  HttpVfsFile({
    required this.url,
    required this.fileSize,
    required SyncHttpFetcher fetcher,
    required LruPageCache cache,
    required ReadAheadStrategy readAhead,
    Map<String, String>? headers,
    HttpVfsConfig? config,
  })  : _fetcher = fetcher,
        _cache = cache,
        _readAhead = readAhead,
        _headers = headers,
        _config = config;

  /// The page cache used by this file handle.
  LruPageCache get cache => _cache;

  @override
  int readInto(Uint8List buffer, int fileOffset) {
    if (fileOffset >= fileSize) {
      return 0; // BaseVfsFile will zero-fill and throw SHORT_READ
    }

    // Clamp read to file bounds
    final bytesToRead = (fileOffset + buffer.length > fileSize)
        ? fileSize - fileOffset
        : buffer.length;

    final pageSize = _cache.pageSize;
    var bufferPos = 0;
    var currentOffset = fileOffset;

    while (bufferPos < bytesToRead) {
      // Which page does this offset fall in?
      final pageStart = (currentOffset ~/ pageSize) * pageSize;
      final offsetInPage = currentOffset - pageStart;

      var page = _cache.get(pageStart);
      if (page == null) {
        // Cache miss — fetch from HTTP with read-ahead
        final remaining = bytesToRead - bufferPos;
        final plan = _readAhead.plan(currentOffset, remaining, fileSize);

        final List<int> data;
        final cfg = _config;
        if (cfg != null && cfg.serverMode == 'chunked') {
          final serverChunkSize = cfg.serverChunkSize!;
          final List<int> mergedData = [];

          for (var chunkId = plan.fetchStart ~/ serverChunkSize;
              chunkId <= plan.fetchEnd ~/ serverChunkSize;
              chunkId++) {
            final chunkStartOffset = chunkId * serverChunkSize;
            final chunkEndOffset = chunkStartOffset + serverChunkSize - 1;

            final fetchStartInDb = max(plan.fetchStart, chunkStartOffset);
            final fetchEndInDb = min(plan.fetchEnd, chunkEndOffset);

            final fromByte = fetchStartInDb - chunkStartOffset;
            final toByte = fetchEndInDb - chunkStartOffset;

            final chunkUrl = _buildChunkUrl(cfg, chunkId);
            final chunkData = _fetcher.fetchRange(
              chunkUrl,
              fromByte,
              toByte,
              headers: _headers,
            );
            fetchCount++;
            mergedData.addAll(chunkData);
          }
          data = mergedData;
        } else {
          final fetchUrl = _buildFullUrl();
          data = _fetcher.fetchRange(
            fetchUrl,
            plan.fetchStart,
            plan.fetchEnd,
            headers: _headers,
          );
          fetchCount++;
        }

        // Store fetched data in cache
        _cache.putBulk(plan.fetchStart, data);

        // Now get the page we actually need
        page = _cache.get(pageStart);
        if (page == null) {
          // Should not happen — we just cached it
          return bufferPos;
        }
      }

      // Copy from page into buffer
      final availableInPage = page.length - offsetInPage;
      final toCopy = (bytesToRead - bufferPos) < availableInPage
          ? (bytesToRead - bufferPos)
          : availableInPage;

      for (var i = 0; i < toCopy; i++) {
        buffer[bufferPos + i] = page[offsetInPage + i];
      }

      bufferPos += toCopy;
      currentOffset += toCopy;
    }

    return bytesToRead;
  }

  String _buildChunkUrl(HttpVfsConfig cfg, int chunkId) {
    final suffix = cfg.cacheBust != null ? '?cb=${cfg.cacheBust}' : '';
    final chunkStr = chunkId.toString().padLeft(cfg.suffixLength!, '0');
    return '${cfg.urlPrefix}$chunkStr$suffix';
  }

  String _buildFullUrl() {
    final cfg = _config;
    if (cfg != null && cfg.serverMode == 'full') {
      final suffix = cfg.cacheBust != null ? '?cb=${cfg.cacheBust}' : '';
      return '${cfg.url}$suffix';
    }
    return url;
  }

  @override
  int xFileSize() => fileSize;

  @override
  void xClose() {
    _cache.clear();
    _readAhead.reset();
  }

  @override
  void xLock(int lockType) {
    // No-op: read-only, no locking needed.
  }

  @override
  void xUnlock(int lockType) {
    // No-op: read-only, no locking needed.
  }

  @override
  int xCheckReservedLock() => 0; // No locks held

  @override
  void xSync(int flags) {
    // No-op: read-only.
  }

  @override
  void xTruncate(int size) {
    // No-op: read-only.
  }

  @override
  void xWrite(Uint8List buffer, int fileOffset) {
    throw VfsException(SqlExtendedError.SQLITE_IOERR_WRITE);
  }

  @override
  int get xDeviceCharacteristics => 0x00008000; // SQLITE_IOCAP_IMMUTABLE
}

/// A minimal in-memory VFS file that appears empty. Used for journal/WAL files
/// that SQLite probes but should not exist for a read-only remote database.
class EmptyVfsFile extends BaseVfsFile {
  @override
  int readInto(Uint8List buffer, int fileOffset) => 0;

  @override
  int xFileSize() => 0;

  @override
  void xClose() {}

  @override
  void xLock(int lockType) {}

  @override
  void xUnlock(int lockType) {}

  @override
  int xCheckReservedLock() => 0;

  @override
  void xSync(int flags) {}

  @override
  void xTruncate(int size) {}

  @override
  void xWrite(Uint8List buffer, int fileOffset) {}

  @override
  int get xDeviceCharacteristics => 0;
}
