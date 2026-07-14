/// Shared HTTP test server that runs in a separate isolate.
///
/// This is necessary because [RawSynchronousSocket] blocks the Dart event loop.
/// If the server and client share an isolate, the server can never respond.
library;

import 'dart:io';
import 'dart:isolate';

import 'test_certs.dart';

/// Starts an HTTP (or HTTPS) file server in a separate isolate and returns
/// the URL.
///
/// The server supports:
/// - HEAD requests → 200 with Content-Length
/// - GET with Range header → 206 Partial Content
/// - GET without Range → 200 with full file
///
/// For byte-buffer mode: pass [data] (serves raw bytes).
/// For file mode: pass [filePath] (serves file from disk).
///
/// Pass `https: true` to serve over TLS using a self-signed cert from
/// [testCertPem]/[testKeyPem].
///
/// Call [TestServer.stop] to shut down.
class TestServer {
  final Isolate _isolate;
  final SendPort _controlPort;
  final String url;
  final int port;

  TestServer._(this._isolate, this._controlPort, this.url, this.port);

  /// Start a test server serving [data] bytes.
  static Future<TestServer> startWithData(
    List<int> data, {
    bool https = false,
  }) async {
    return _start({'type': 'data', 'data': data, 'https': https});
  }

  /// Start a test server serving a file from [filePath].
  static Future<TestServer> startWithFile(
    String filePath, {
    bool https = false,
  }) async {
    return _start({'type': 'file', 'path': filePath, 'https': https});
  }

  /// Start a test server serving files from [dirPath] directory.
  static Future<TestServer> startWithDirectory(
    String dirPath, {
    bool https = false,
  }) async {
    return _start({'type': 'directory', 'path': dirPath, 'https': https});
  }

  static Future<TestServer> _start(Map<String, Object> config) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _serverEntryPoint,
      {'sendPort': receivePort.sendPort, ...config},
    );

    // Wait for the server to report its port and control port
    final msg = await receivePort.first as Map<String, Object>;
    final port = msg['port'] as int;
    final controlPort = msg['controlPort'] as SendPort;
    final scheme = (config['https'] as bool? ?? false) ? 'https' : 'http';
    final url = config['type'] == 'directory'
        ? '$scheme://127.0.0.1:$port/'
        : '$scheme://127.0.0.1:$port/test.db';

    return TestServer._(isolate, controlPort, url, port);
  }

  /// Stop the server and kill the isolate.
  Future<void> stop() async {
    _controlPort.send('stop');
    // Give server time to shut down
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// Entry point for the server isolate.
void _serverEntryPoint(Map<String, Object> config) async {
  final sendPort = config['sendPort'] as SendPort;
  final controlPort = ReceivePort();

  final isDirectory = config['type'] == 'directory';
  final dirPath = isDirectory ? config['path'] as String : null;

  List<int>? fileBytes;
  if (config['type'] == 'file') {
    fileBytes = File(config['path'] as String).readAsBytesSync();
  } else if (config['type'] == 'data') {
    fileBytes = config['data'] as List<int>;
  }

  final useHttps = config['https'] as bool? ?? false;
  final HttpServer server;
  if (useHttps) {
    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(testCertPem.codeUnits)
      ..usePrivateKeyBytes(testKeyPem.codeUnits);
    server = await HttpServer.bindSecure('127.0.0.1', 0, ctx);
  } else {
    server = await HttpServer.bind('127.0.0.1', 0);
  }

  // Report port back to parent
  sendPort.send({
    'port': server.port,
    'controlPort': controlPort.sendPort,
  });

  // Listen for stop signal
  controlPort.listen((message) async {
    if (message == 'stop') {
      await server.close(force: true);
    }
  });

  await for (final request in server) {
    final response = request.response;

    List<int> currentBytes;
    if (isDirectory) {
      var reqPath = request.uri.path;
      if (reqPath.startsWith('/')) {
        reqPath = reqPath.substring(1);
      }
      final file = File('$dirPath/$reqPath');
      if (!file.existsSync()) {
        response.statusCode = 404;
        await response.close();
        continue;
      }
      currentBytes = file.readAsBytesSync();
    } else {
      currentBytes = fileBytes!;
    }

    if (request.method == 'HEAD') {
      response.statusCode = 200;
      response.headers.contentLength = currentBytes.length;
      response.headers.set('accept-ranges', 'bytes');
      await response.close();
      continue;
    }

    final rangeHeader = request.headers.value('range');
    if (rangeHeader != null) {
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        final clampedEnd = end >= currentBytes.length ? currentBytes.length - 1 : end;

        response.statusCode = 206;
        response.headers.contentLength = clampedEnd - start + 1;
        response.headers.set(
          'content-range',
          'bytes $start-$clampedEnd/${currentBytes.length}',
        );
        response.add(currentBytes.sublist(start, clampedEnd + 1));
        await response.close();
        continue;
      }
    }

    // Full file response
    response.statusCode = 200;
    response.headers.contentLength = currentBytes.length;
    response.add(currentBytes);
    await response.close();
  }
}
