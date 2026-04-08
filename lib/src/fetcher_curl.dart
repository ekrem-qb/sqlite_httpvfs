import 'dart:io';

import 'constants.dart';
import 'fetcher.dart';

/// Synchronous HTTP fetcher using `curl` via [Process.runSync].
///
/// Supports **HTTPS** but only works on platforms where `curl` is installed
/// (macOS, Linux, Windows 10+). Not available on iOS or Android — use
/// [SocketFetcher] for HTTP or the async prefetch API for HTTPS on mobile.
class CurlFetcher implements SyncHttpFetcher {
  /// Path to the curl binary.
  final String curlPath;

  /// Timeout for curl operations in seconds.
  final int timeoutSeconds;

  /// Extra arguments to pass to curl (e.g. `['--insecure']` for self-signed).
  final List<String> extraArgs;

  /// Optional extra headers to include in every request.
  final Map<String, String>? defaultHeaders;

  CurlFetcher({
    this.curlPath = 'curl',
    this.timeoutSeconds = defaultTimeoutSeconds,
    this.extraArgs = const [],
    this.defaultHeaders,
  });

  @override
  List<int> fetchRange(
    String url,
    int start,
    int end, {
    Map<String, String>? headers,
  }) {
    final args = <String>[
      '--silent',
      '--fail',
      '--show-error',
      '--location', // follow redirects
      '--max-time',
      '$timeoutSeconds',
      '-H',
      'Range: bytes=$start-$end',
      ...extraArgs,
      ..._headerArgs({...?defaultHeaders, ...?headers}),
      '-o',
      '-', // write to stdout
      url,
    ];

    final result = Process.runSync(
      curlPath,
      args,
      stdoutEncoding: null, // raw bytes
    );

    if (result.exitCode != 0) {
      final stderr = result.stderr as String;
      throw FetchException(
        'curl failed (exit ${result.exitCode}): $stderr',
      );
    }

    return result.stdout as List<int>;
  }

  @override
  int fetchFileSize(String url, {Map<String, String>? headers}) {
    final args = <String>[
      '--silent',
      '--fail',
      '--show-error',
      '--location', // follow redirects
      '--head',
      '--max-time',
      '$timeoutSeconds',
      ...extraArgs,
      ..._headerArgs({...?defaultHeaders, ...?headers}),
      url,
    ];

    final result = Process.runSync(curlPath, args);

    if (result.exitCode != 0) {
      final stderr = result.stderr as String;
      throw FetchException(
        'curl HEAD failed (exit ${result.exitCode}): $stderr',
      );
    }

    final stdout = result.stdout as String;
    final match = RegExp(
      r'content-length:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(stdout);

    if (match == null) {
      throw FetchException('HEAD $url: no Content-Length in response');
    }

    return int.parse(match.group(1)!);
  }

  List<String> _headerArgs(Map<String, String> headers) {
    return [
      for (final entry in headers.entries) ...['-H', '${entry.key}: ${entry.value}'],
    ];
  }
}
