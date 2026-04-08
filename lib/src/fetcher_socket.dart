import 'dart:io';
import 'dart:typed_data';

import 'constants.dart';
import 'fetcher.dart';

/// Synchronous HTTP fetcher using [RawSynchronousSocket].
///
/// Works on **all native Dart platforms** (iOS, Android, macOS, Linux, Windows).
/// Limitation: plain HTTP only — no TLS/HTTPS support. Use [CurlFetcher] for
/// HTTPS or the async prefetch API.
///
/// Ideal for local IPFS gateways (`http://localhost:8080`), LAN servers, or
/// any HTTP endpoint.
class SocketFetcher implements SyncHttpFetcher {
  /// Timeout for socket operations in seconds.
  final int timeoutSeconds;

  /// Optional extra headers to include in every request.
  final Map<String, String>? defaultHeaders;

  /// Maximum number of redirects to follow before giving up.
  final int maxRedirects;

  SocketFetcher({
    this.timeoutSeconds = defaultTimeoutSeconds,
    this.defaultHeaders,
    this.maxRedirects = 5,
  });

  @override
  List<int> fetchRange(
    String url,
    int start,
    int end, {
    Map<String, String>? headers,
  }) {
    var uri = Uri.parse(url);
    _assertHttp(uri);

    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      final allHeaders = <String, String>{
        'Host': _hostHeader(uri),
        'Range': 'bytes=$start-$end',
        'Connection': 'close',
        ...?defaultHeaders,
        ...?headers,
      };

      final response = _request('GET', uri, allHeaders);

      // Follow redirects
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null) {
          throw FetchException(
            'GET $uri returned ${response.statusCode} with no Location header',
            statusCode: response.statusCode,
          );
        }
        uri = _resolveRedirect(uri, location);
        _assertHttp(uri);
        continue;
      }

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw FetchException(
          'GET $url returned ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      return response.body;
    }

    throw FetchException('GET $url: too many redirects (>$maxRedirects)');
  }

  @override
  int fetchFileSize(String url, {Map<String, String>? headers}) {
    var uri = Uri.parse(url);
    _assertHttp(uri);

    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      final allHeaders = <String, String>{
        'Host': _hostHeader(uri),
        'Connection': 'close',
        ...?defaultHeaders,
        ...?headers,
      };

      final response = _request('HEAD', uri, allHeaders);

      // Follow redirects
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null) {
          throw FetchException(
            'HEAD $uri returned ${response.statusCode} with no Location header',
            statusCode: response.statusCode,
          );
        }
        uri = _resolveRedirect(uri, location);
        _assertHttp(uri);
        continue;
      }

      if (response.statusCode != 200) {
        throw FetchException(
          'HEAD $url returned ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      final contentLength = response.headers['content-length'];
      if (contentLength == null) {
        throw FetchException('HEAD $url: no Content-Length header');
      }

      final size = int.tryParse(contentLength);
      if (size == null) {
        throw FetchException(
          'HEAD $url: invalid Content-Length "$contentLength"',
        );
      }

      return size;
    }

    throw FetchException('HEAD $url: too many redirects (>$maxRedirects)');
  }

  /// Returns true for 3xx redirect status codes.
  bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  /// Resolve a possibly-relative Location header against the current URI.
  Uri _resolveRedirect(Uri current, String location) {
    final locationUri = Uri.parse(location);
    if (locationUri.hasScheme) return locationUri;
    // Relative redirect — resolve against current URI.
    return current.resolveUri(locationUri);
  }

  void _assertHttp(Uri uri) {
    if (uri.scheme != 'http') {
      throw FetchException(
        'SocketFetcher only supports http:// URLs (got ${uri.scheme}://). '
        'Use CurlFetcher for HTTPS or the async prefetch API.',
      );
    }
  }

  String _hostHeader(Uri uri) {
    if (uri.port != 80 && uri.port != 0) {
      return '${uri.host}:${uri.port}';
    }
    return uri.host;
  }

  _HttpResponse _request(
    String method,
    Uri uri,
    Map<String, String> headers,
  ) {
    final host = uri.host;
    final port = uri.port == 0 ? 80 : uri.port;
    final path = uri.path.isEmpty ? '/' : uri.path;
    final query = uri.query.isNotEmpty ? '?${uri.query}' : '';

    final socket = RawSynchronousSocket.connectSync(host, port);

    try {
      // Build HTTP/1.1 request
      final request = StringBuffer()
        ..write('$method $path$query HTTP/1.1\r\n');
      for (final entry in headers.entries) {
        request.write('${entry.key}: ${entry.value}\r\n');
      }
      request.write('\r\n');

      socket.writeFromSync(request.toString().codeUnits);

      // Read response
      return _readResponse(socket, method == 'HEAD');
    } finally {
      socket.closeSync();
    }
  }

  _HttpResponse _readResponse(RawSynchronousSocket socket, bool headOnly) {
    // Read until we have the full header block
    final headerBytes = <int>[];
    var headerEnd = -1;

    while (headerEnd == -1) {
      final chunk = socket.readSync(4096);
      if (chunk == null || chunk.isEmpty) break;
      headerBytes.addAll(chunk);
      headerEnd = _findHeaderEnd(headerBytes);
    }

    if (headerEnd == -1) {
      throw FetchException('Connection closed before headers received');
    }

    // Parse status line and headers
    final headerStr = String.fromCharCodes(headerBytes.sublist(0, headerEnd));
    final lines = headerStr.split('\r\n');
    if (lines.isEmpty) {
      throw FetchException('Empty HTTP response');
    }

    // Parse "HTTP/1.1 200 OK"
    final statusMatch = RegExp(r'HTTP/\d\.\d\s+(\d+)').firstMatch(lines[0]);
    if (statusMatch == null) {
      throw FetchException('Invalid HTTP status line: ${lines[0]}');
    }
    final statusCode = int.parse(statusMatch.group(1)!);

    // Parse headers
    final responseHeaders = <String, String>{};
    for (var i = 1; i < lines.length; i++) {
      final colonIdx = lines[i].indexOf(':');
      if (colonIdx > 0) {
        final key = lines[i].substring(0, colonIdx).trim().toLowerCase();
        final value = lines[i].substring(colonIdx + 1).trim();
        responseHeaders[key] = value;
      }
    }

    if (headOnly) {
      return _HttpResponse(statusCode, responseHeaders, const []);
    }

    // Body starts after header end + \r\n\r\n (4 bytes)
    final bodyStart = headerEnd + 4;
    final initialBody = headerBytes.sublist(bodyStart);

    // Determine body length
    final transferEncoding = responseHeaders['transfer-encoding'];
    if (transferEncoding != null && transferEncoding.contains('chunked')) {
      return _HttpResponse(
        statusCode,
        responseHeaders,
        _readChunkedBody(socket, initialBody),
      );
    }

    final contentLengthStr = responseHeaders['content-length'];
    if (contentLengthStr != null) {
      final contentLength = int.parse(contentLengthStr);
      final body = Uint8List(contentLength);
      var offset = 0;

      // Copy initial body bytes
      final toCopy =
          initialBody.length < contentLength ? initialBody.length : contentLength;
      body.setRange(0, toCopy, initialBody);
      offset = toCopy;

      // Read remaining
      while (offset < contentLength) {
        final chunk = socket.readSync(contentLength - offset);
        if (chunk == null || chunk.isEmpty) break;
        body.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }

      return _HttpResponse(statusCode, responseHeaders, body);
    }

    // No content-length, no chunked — read until connection closes
    final body = <int>[...initialBody];
    while (true) {
      final chunk = socket.readSync(8192);
      if (chunk == null || chunk.isEmpty) break;
      body.addAll(chunk);
    }
    return _HttpResponse(statusCode, responseHeaders, body);
  }

  /// Find the \r\n\r\n boundary that separates headers from body.
  int _findHeaderEnd(List<int> data) {
    for (var i = 0; i < data.length - 3; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// Read a chunked transfer-encoded body.
  List<int> _readChunkedBody(
    RawSynchronousSocket socket,
    List<int> initialData,
  ) {
    final buffer = <int>[...initialData];
    final result = <int>[];

    while (true) {
      // Ensure we have enough data to read a chunk header
      while (!_containsLine(buffer)) {
        final chunk = socket.readSync(4096);
        if (chunk == null || chunk.isEmpty) return result;
        buffer.addAll(chunk);
      }

      // Parse chunk size
      final lineEnd = _findLineEnd(buffer);
      final sizeStr = String.fromCharCodes(buffer.sublist(0, lineEnd)).trim();
      buffer.removeRange(0, lineEnd + 2); // skip \r\n

      final chunkSize = int.parse(sizeStr, radix: 16);
      if (chunkSize == 0) break;

      // Read chunk data
      while (buffer.length < chunkSize + 2) {
        final data = socket.readSync(chunkSize + 2 - buffer.length);
        if (data == null || data.isEmpty) return result;
        buffer.addAll(data);
      }

      result.addAll(buffer.sublist(0, chunkSize));
      buffer.removeRange(0, chunkSize + 2); // skip chunk data + \r\n
    }

    return result;
  }

  bool _containsLine(List<int> data) => _findLineEnd(data) >= 0;

  int _findLineEnd(List<int> data) {
    for (var i = 0; i < data.length - 1; i++) {
      if (data[i] == 13 && data[i + 1] == 10) return i;
    }
    return -1;
  }
}

class _HttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final List<int> body;

  _HttpResponse(this.statusCode, this.headers, this.body);
}
