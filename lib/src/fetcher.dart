import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_httpvfs/src/request.dart';

const int _kMaxAttempts = 100;

class AsyncHttpFetcher {
  final HttpClient _httpClient;
  final bool _isHttpClientOwned;

  final bool allowSelfSigned;

  final Map<SizeRequest, FutureOr<int>> _sizesStorage = {};
  final Map<RangeRequest, FutureOr<Uint8List>> _rangesStorage = {};

  int _pendingCount = 0;

  bool _disposed = false;

  AsyncHttpFetcher({
    HttpClient? httpClient = null,
    this.allowSelfSigned = false,
  })  : _httpClient = httpClient ?? HttpClient(),
        _isHttpClientOwned = httpClient == null {
    if (allowSelfSigned) {
      _httpClient.badCertificateCallback = (_, __, ___) => true;
    }
  }

  /// Returns `true` if there are any pending requests that need to be loaded.
  bool get hasPending => _pendingCount > 0;

  void close() {
    if (_isHttpClientOwned) {
      _httpClient.close();
    }
    _disposed = true;
  }

  /// Fetch bytes in the range [start, end] (inclusive) from [url].
  ///
  /// Returns the raw response body bytes. If the server returns 200 instead
  /// of 206, the full response body is returned (caller should cache it).
  ///
  /// Throws [FetchException] on network errors or non-2xx responses.
  Uint8List fetchRange(RangeRequest request) {
    if (_disposed) {
      throw FetchException('AsyncHttpFetcher has been disposed');
    }

    switch (_rangesStorage[request]) {
      case final Uint8List value:
        _rangesStorage.remove(request);
        return value;
      case null:
        _rangesStorage[request] = _loadRange(request).then(
          (value) => _rangesStorage[request] = value,
        );
      case Future():
        break;
    }
    throw const PendingFetchException();
  }

  /// Get the total file size at [url] via an HTTP HEAD request.
  ///
  /// Returns the value of the `Content-Length` header.
  /// Throws [FetchException] if the size cannot be determined.
  int fetchFileSize(
    String url, {
    Map<String, String>? headers,
  }) {
    if (_disposed) {
      throw FetchException('AsyncHttpFetcher has been disposed');
    }

    final SizeRequest key = (
      url: url,
      headers: headers != null ? RequestHeaders(headers) : null,
    );

    switch (_sizesStorage[key]) {
      case final int value:
        _sizesStorage.remove(key);
        return value;
      case null:
        _sizesStorage[key] = _loadSize(key).then(
          (value) => _sizesStorage[key] = value,
        );
      case Future():
        break;
    }
    throw const PendingFetchException();
  }

  /// Pre-registers a range request so it can be fetched in parallel.
  ///
  /// Returns the [RangeRequest] key that was built, so callers can pass it
  /// directly to [fetchRangeByKey] to avoid constructing the key a second time.
  RangeRequest preRegisterRange(
    String url,
    int start,
    int end, {
    Map<String, String>? headers,
  }) {
    if (_disposed) {
      throw FetchException('AsyncHttpFetcher has been disposed');
    }

    final RangeRequest key = (
      url: url,
      start: start,
      end: end,
      headers: headers != null ? RequestHeaders(headers) : null,
    );
    if (!_rangesStorage.containsKey(key)) {
      _rangesStorage[key] = _loadRange(key).then(
        (value) => _rangesStorage[key] = value,
      );
    }
    return key;
  }

  Future<void> loadPending() async {
    await Future.wait(
      [
        for (final v in _sizesStorage.values)
          if (v is Future<int>) v,
        for (final v in _rangesStorage.values)
          if (v is Future<Uint8List>) v,
      ],
      eagerError: false,
    );
  }

  Future<int> _loadSize(SizeRequest sizeRequest) async {
    _pendingCount++;
    try {
      final request = await _httpClient.headUrl(Uri.parse(sizeRequest.url));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      sizeRequest.headers
          ?.forEach((k, v) => request.headers.set(k, v.toString()));
      final response = await request.close();

      if (response.contentLength < 1) {
        throw FetchException(
          response.connectionInfo.toString(),
          statusCode: response.statusCode,
        );
      }

      return response.headers.contentLength;
    } finally {
      _pendingCount--;
    }
  }

  Future<Uint8List> _loadRange(RangeRequest rangeRequest) async {
    _pendingCount++;
    final request = await _httpClient.getUrl(Uri.parse(rangeRequest.url));
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=${rangeRequest.start}-${rangeRequest.end}',
    );
    rangeRequest.headers
        ?.forEach((k, v) => request.headers.set(k, v.toString()));
    final response = await request.close();

    if (response.contentLength < 1) {
      throw FetchException(
        response.connectionInfo.toString(),
        statusCode: response.statusCode,
      );
    }

    try {
      final bytes = Uint8List(response.contentLength);
      var offset = 0;
      final completer = Completer<void>();

      response.listen(
        (chunk) {
          bytes.setAll(offset, chunk);
          offset += chunk.length;
        },
        onDone: completer.complete,
        onError: completer.completeError,
        cancelOnError: true,
      );

      await completer.future;

      return bytes;
    } catch (_) {
      return Uint8List(0);
    } finally {
      _pendingCount--;
    }
  }

  Future<T> waitForValid<T>(T Function() action) async {
    int attempts = 0;
    while (true) {
      try {
        return action();
      } on PendingFetchException {
        if (!hasPending) {
          rethrow;
        }
        attempts++;
        if (attempts >= _kMaxAttempts) {
          rethrow;
        }
        await loadPending();
      }
    }
  }
}

/// Exception thrown by [AsyncHttpFetcher] when a range or size request is
/// pending and needs to be awaited.
class PendingFetchException implements Exception {
  const PendingFetchException();

  @override
  String toString() => 'PendingFetchException: Request is pending';
}

/// Exception thrown by [AsyncHttpFetcher] implementations on failure.
class FetchException implements Exception {
  final String message;
  final int? statusCode;

  FetchException(this.message, {this.statusCode});

  @override
  String toString() => 'FetchException: $message'
      '${statusCode != null ? ' (HTTP $statusCode)' : ''}';
}
