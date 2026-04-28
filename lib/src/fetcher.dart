import 'fetcher_curl.dart';
import 'fetcher_isolate.dart';
import 'fetcher_socket.dart';

/// Abstract interface for synchronous HTTP range-request fetching.
///
/// SQLite's VFS `xRead` callback is synchronous — it must return data
/// immediately and cannot `await` a Future. Implementations of this
/// interface provide synchronous HTTP access for use inside VFS callbacks.
abstract class SyncHttpFetcher {
  /// Fetch bytes in the range [start, end] (inclusive) from [url].
  ///
  /// Returns the raw response body bytes. If the server returns 200 instead
  /// of 206, the full response body is returned (caller should cache it).
  ///
  /// Throws [FetchException] on network errors or non-2xx responses.
  List<int> fetchRange(
    String url,
    int start,
    int end, {
    Map<String, String>? headers,
  });

  /// Get the total file size at [url] via an HTTP HEAD request.
  ///
  /// Returns the value of the `Content-Length` header.
  /// Throws [FetchException] if the size cannot be determined.
  int fetchFileSize(String url, {Map<String, String>? headers});
}

/// Exception thrown by [SyncHttpFetcher] implementations on failure.
class FetchException implements Exception {
  final String message;
  final int? statusCode;

  FetchException(this.message, {this.statusCode});

  @override
  String toString() => 'FetchException: $message'
      '${statusCode != null ? ' (HTTP $statusCode)' : ''}';
}

/// Creates an appropriate [SyncHttpFetcher] synchronously based on the URL scheme.
///
/// - `https://` → [CurlFetcher] (requires curl, desktop only)
/// - `http://` → [SocketFetcher] (cross-platform, all native)
///
/// Prefer [createFetcherAsync] for HTTPS on iOS/Android — it returns an
/// [IsolateFetcher] that uses platform-native TLS without depending on `curl`.
SyncHttpFetcher createFetcher(String url) {
  final scheme = Uri.parse(url).scheme;
  if (scheme == 'https') {
    return CurlFetcher();
  }
  return SocketFetcher();
}

/// Creates an appropriate [SyncHttpFetcher] for [url], using [IsolateFetcher]
/// for HTTPS so HTTPS works on every platform Dart runs on (iOS and Android
/// included), without requiring `curl` to be installed.
///
/// - `https://` → [IsolateFetcher] (cross-platform, native TLS via `dart:io`)
/// - `http://` → [SocketFetcher] (cross-platform, sync sockets)
///
/// The returned fetcher may hold a worker isolate; call `dispose()` on it
/// (if it is an [IsolateFetcher]) when you're done.
Future<SyncHttpFetcher> createFetcherAsync(
  String url, {
  Map<String, String>? defaultHeaders,
  bool allowSelfSigned = false,
}) async {
  final scheme = Uri.parse(url).scheme;
  if (scheme == 'https') {
    return IsolateFetcher.create(
      defaultHeaders: defaultHeaders,
      allowSelfSigned: allowSelfSigned,
    );
  }
  return SocketFetcher(defaultHeaders: defaultHeaders);
}
