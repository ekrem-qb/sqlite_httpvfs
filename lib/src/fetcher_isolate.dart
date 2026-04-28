import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'constants.dart';
import 'fetcher.dart';

/// Synchronous HTTP/HTTPS fetcher that bridges sync ↔ async via a worker isolate.
///
/// Cross-platform (iOS, Android, macOS, Linux, Windows) — uses only `dart:io`
/// and `dart:isolate`, no native plugins or external binaries.
///
/// Architecture:
/// - A worker isolate hosts a loopback `ServerSocket` and a single pooled
///   [HttpClient] that handles platform-native TLS for `https://` URLs.
/// - The main isolate connects **once** via [RawSynchronousSocket] and reuses
///   that connection for every request. Each request is framed and the worker
///   replies on the same socket.
/// - Upstream connections are kept alive by the worker's [HttpClient], so a
///   sequence of range reads against the same host avoids repeated TLS
///   handshakes.
///
/// Construction is asynchronous; use [IsolateFetcher.create].
class IsolateFetcher implements SyncHttpFetcher {
  final Isolate _worker;
  final RawSynchronousSocket _socket;
  final ReceivePort _exitPort;
  final Map<String, String>? defaultHeaders;
  final int timeoutSeconds;
  bool _disposed = false;

  IsolateFetcher._({
    required Isolate worker,
    required RawSynchronousSocket socket,
    required ReceivePort exitPort,
    required this.defaultHeaders,
    required this.timeoutSeconds,
  })  : _worker = worker,
        _socket = socket,
        _exitPort = exitPort;

  /// Spawn the worker isolate and connect the persistent loopback socket.
  ///
  /// [allowSelfSigned] disables certificate validation for HTTPS — only use
  /// for local test servers with self-signed certs.
  static Future<IsolateFetcher> create({
    Map<String, String>? defaultHeaders,
    int timeoutSeconds = defaultTimeoutSeconds,
    bool allowSelfSigned = false,
  }) async {
    final readyPort = ReceivePort();
    final exitPort = ReceivePort();

    final worker = await Isolate.spawn(
      _workerEntry,
      _WorkerInit(
        readyPort.sendPort,
        timeoutSeconds: timeoutSeconds,
        allowSelfSigned: allowSelfSigned,
      ),
      onExit: exitPort.sendPort,
      errorsAreFatal: true,
    );

    final ready = await readyPort.first as int;
    readyPort.close();

    final socket = RawSynchronousSocket.connectSync(
      InternetAddress.loopbackIPv4.address,
      ready,
    );

    return IsolateFetcher._(
      worker: worker,
      socket: socket,
      exitPort: exitPort,
      defaultHeaders: defaultHeaders,
      timeoutSeconds: timeoutSeconds,
    );
  }

  @override
  List<int> fetchRange(
    String url,
    int start,
    int end, {
    Map<String, String>? headers,
  }) {
    final merged = <String, String>{
      ...?defaultHeaders,
      ...?headers,
      'Range': 'bytes=$start-$end',
    };
    return _request('GET', url, merged).body;
  }

  @override
  int fetchFileSize(String url, {Map<String, String>? headers}) {
    final merged = <String, String>{...?defaultHeaders, ...?headers};
    final resp = _request('HEAD', url, merged);
    final cl = resp.headers['content-length'];
    if (cl == null) {
      throw FetchException('HEAD $url: no Content-Length header');
    }
    final size = int.tryParse(cl);
    if (size == null) {
      throw FetchException('HEAD $url: invalid Content-Length "$cl"');
    }
    return size;
  }

  _Response _request(String method, String url, Map<String, String> headers) {
    if (_disposed) {
      throw FetchException('IsolateFetcher has been disposed');
    }

    final meta = utf8.encode(jsonEncode({
      'method': method,
      'url': url,
      'headers': headers,
    }));

    final lenBuf = ByteData(4)..setUint32(0, meta.length, Endian.big);
    _socket.writeFromSync(lenBuf.buffer.asUint8List());
    _socket.writeFromSync(meta);

    final ok = _readExactly(1)[0];
    final status = _readI32();
    final infoLen = _readU32();
    final info = _readExactly(infoLen);

    if (ok == 0) {
      throw FetchException(
        utf8.decode(info),
        statusCode: status == _noStatus ? null : status,
      );
    }

    final headersJson = jsonDecode(utf8.decode(info)) as Map<String, dynamic>;
    final responseHeaders = <String, String>{
      for (final e in headersJson.entries) e.key: e.value as String,
    };

    final bodyLen = _readU32();
    final body = _readExactly(bodyLen);

    return _Response(status, responseHeaders, body);
  }

  Uint8List _readExactly(int n) {
    if (n == 0) return Uint8List(0);
    final out = Uint8List(n);
    var off = 0;
    while (off < n) {
      final chunk = _socket.readSync(n - off);
      if (chunk == null || chunk.isEmpty) {
        throw FetchException('Worker connection closed unexpectedly');
      }
      out.setRange(off, off + chunk.length, chunk);
      off += chunk.length;
    }
    return out;
  }

  int _readU32() =>
      ByteData.sublistView(_readExactly(4)).getUint32(0, Endian.big);

  int _readI32() =>
      ByteData.sublistView(_readExactly(4)).getInt32(0, Endian.big);

  /// Tear down the worker isolate and close the loopback connection.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _socket.closeSync();
    } catch (_) {}
    _worker.kill(priority: Isolate.immediate);
    await _exitPort.first
        .timeout(const Duration(seconds: 2), onTimeout: () => null);
    _exitPort.close();
  }
}

/// Sentinel for "no HTTP status code available" in error responses.
const int _noStatus = -1;

class _Response {
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
  _Response(this.statusCode, this.headers, this.body);
}

class _WorkerInit {
  final SendPort readyPort;
  final int timeoutSeconds;
  final bool allowSelfSigned;
  _WorkerInit(
    this.readyPort, {
    required this.timeoutSeconds,
    required this.allowSelfSigned,
  });
}

void _workerEntry(_WorkerInit init) async {
  final client = HttpClient()
    ..idleTimeout = const Duration(seconds: 60)
    ..connectionTimeout = Duration(seconds: init.timeoutSeconds)
    ..autoUncompress = false;
  if (init.allowSelfSigned) {
    client.badCertificateCallback = (_, __, ___) => true;
  }

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  init.readyPort.send(server.port);

  await for (final conn in server) {
    conn.setOption(SocketOption.tcpNoDelay, true);
    _serveConnection(conn, client, init.timeoutSeconds);
  }
}

void _serveConnection(Socket conn, HttpClient client, int timeoutSeconds) {
  final reader = _SocketReader(conn);
  Future<void>.microtask(() async {
    try {
      while (true) {
        final lenBytes = await reader.readExact(4);
        if (lenBytes == null) return;
        final metaLen =
            ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
        final metaBytes = await reader.readExact(metaLen);
        if (metaBytes == null) return;

        final meta = jsonDecode(utf8.decode(metaBytes)) as Map<String, dynamic>;
        await _handleRequest(conn, client, meta, timeoutSeconds);
      }
    } catch (e) {
      try {
        _writeError(conn, e.toString(), _noStatus);
        await conn.flush();
      } catch (_) {}
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  });
}

Future<void> _handleRequest(
  Socket conn,
  HttpClient client,
  Map<String, dynamic> meta,
  int timeoutSeconds,
) async {
  final method = meta['method'] as String;
  final url = meta['url'] as String;
  final rawHeaders = meta['headers'] as Map<String, dynamic>? ?? const {};

  try {
    final uri = Uri.parse(url);
    final timeout = Duration(seconds: timeoutSeconds);
    final request = await client.openUrl(method, uri).timeout(timeout);

    request.followRedirects = true;
    request.maxRedirects = 5;
    rawHeaders.forEach((k, v) => request.headers.set(k, v.toString()));

    final response = await request.close().timeout(timeout);

    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });

    Uint8List body;
    if (method == 'HEAD') {
      await response.drain<void>();
      body = Uint8List(0);
    } else {
      final contentLen = response.headers.contentLength;
      if (contentLen >= 0) {
        body = Uint8List(contentLen);
        var off = 0;
        await for (final chunk in response) {
          body.setRange(off, off + chunk.length, chunk);
          off += chunk.length;
        }
        if (off != contentLen) {
          body = Uint8List.sublistView(body, 0, off);
        }
      } else {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          builder.add(chunk);
        }
        body = builder.takeBytes();
      }
    }

    _writeOk(conn, response.statusCode, headers, body);
    await conn.flush();
  } catch (e) {
    int status = _noStatus;
    if (e is HttpException) {
      // No status available from HttpException directly.
    }
    _writeError(conn, e.toString(), status);
    await conn.flush();
  }
}

void _writeOk(
  Socket conn,
  int status,
  Map<String, String> headers,
  Uint8List body,
) {
  final hdrJson = utf8.encode(jsonEncode(headers));
  final prefix = ByteData(1 + 4 + 4)
    ..setUint8(0, 1)
    ..setInt32(1, status, Endian.big)
    ..setUint32(5, hdrJson.length, Endian.big);
  conn.add(prefix.buffer.asUint8List());
  conn.add(hdrJson);
  final bodyLen = ByteData(4)..setUint32(0, body.length, Endian.big);
  conn.add(bodyLen.buffer.asUint8List());
  if (body.isNotEmpty) conn.add(body);
}

void _writeError(Socket conn, String message, int status) {
  final msg = utf8.encode(message);
  final prefix = ByteData(1 + 4 + 4)
    ..setUint8(0, 0)
    ..setInt32(1, status, Endian.big)
    ..setUint32(5, msg.length, Endian.big);
  conn.add(prefix.buffer.asUint8List());
  conn.add(msg);
}

/// Buffers a [Stream<List<int>>] and exposes an async `readExact` API.
class _SocketReader {
  final List<List<int>> _queued = [];
  int _queuedLen = 0;
  Completer<void>? _waiter;
  bool _closed = false;
  Object? _error;
  StackTrace? _errorStack;

  _SocketReader(Stream<List<int>> stream) {
    stream.listen(
      (data) {
        _queued.add(data);
        _queuedLen += data.length;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      onError: (Object e, StackTrace st) {
        _error = e;
        _errorStack = st;
        _closed = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) {
      if (_error != null) {
        w.completeError(_error!, _errorStack);
      } else {
        w.complete();
      }
    }
  }

  Future<Uint8List?> readExact(int n) async {
    while (_queuedLen < n) {
      if (_closed) {
        if (_error != null) {
          // ignore: only_throw_errors
          throw _error!;
        }
        return null;
      }
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = Uint8List(n);
    var off = 0;
    while (off < n) {
      final first = _queued.first;
      final remaining = n - off;
      if (first.length <= remaining) {
        out.setRange(off, off + first.length, first);
        off += first.length;
        _queuedLen -= first.length;
        _queued.removeAt(0);
      } else {
        out.setRange(off, off + remaining, first);
        _queued[0] = first.sublist(remaining);
        _queuedLen -= remaining;
        off += remaining;
      }
    }
    return out;
  }
}
