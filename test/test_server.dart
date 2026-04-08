/// Shared HTTP test server that runs in a separate isolate.
///
/// This is necessary because [RawSynchronousSocket] blocks the Dart event loop.
/// If the server and client share an isolate, the server can never respond.
library;

import 'dart:io';
import 'dart:isolate';

/// Starts an HTTP file server in a separate isolate and returns the URL.
///
/// The server supports:
/// - HEAD requests → 200 with Content-Length
/// - GET with Range header → 206 Partial Content
/// - GET without Range → 200 with full file
///
/// For byte-buffer mode: pass [data] (serves raw bytes).
/// For file mode: pass [filePath] (serves file from disk).
///
/// Call [TestServer.stop] to shut down.
class TestServer {
  final Isolate _isolate;
  final SendPort _controlPort;
  final String url;
  final int port;

  TestServer._(this._isolate, this._controlPort, this.url, this.port);

  /// Start a test server serving [data] bytes.
  static Future<TestServer> startWithData(List<int> data) async {
    return _start({'type': 'data', 'data': data});
  }

  /// Start a test server serving a file from [filePath].
  static Future<TestServer> startWithFile(String filePath) async {
    return _start({'type': 'file', 'path': filePath});
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
    final url = 'http://127.0.0.1:$port/test.db';

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

  List<int> fileBytes;
  if (config['type'] == 'file') {
    fileBytes = File(config['path'] as String).readAsBytesSync();
  } else {
    fileBytes = config['data'] as List<int>;
  }

  final server = await HttpServer.bind('127.0.0.1', 0);

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

    if (request.method == 'HEAD') {
      response.statusCode = 200;
      response.headers.contentLength = fileBytes.length;
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
        final clampedEnd = end >= fileBytes.length ? fileBytes.length - 1 : end;

        response.statusCode = 206;
        response.headers.contentLength = clampedEnd - start + 1;
        response.headers.set(
          'content-range',
          'bytes $start-$clampedEnd/${fileBytes.length}',
        );
        response.add(fileBytes.sublist(start, clampedEnd + 1));
        await response.close();
        continue;
      }
    }

    // Full file response
    response.statusCode = 200;
    response.headers.contentLength = fileBytes.length;
    response.add(fileBytes);
    await response.close();
  }
}
