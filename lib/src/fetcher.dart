import 'fetcher_curl.dart';
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

/// Creates an appropriate [SyncHttpFetcher] based on the URL scheme.
///
/// - `https://` → [CurlFetcher] (requires curl, desktop only)
/// - `http://` → [SocketFetcher] (cross-platform, all native)
SyncHttpFetcher createFetcher(String url) {
  final scheme = Uri.parse(url).scheme;
  if (scheme == 'https') {
    return CurlFetcher();
  }
  return SocketFetcher();
}
