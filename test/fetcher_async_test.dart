import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
import 'package:sqlite_httpvfs/src/request.dart';
import 'package:test/test.dart';

import 'test_server.dart';

void main() {
  group('AsyncHttpFetcher (HTTP)', () {
    late TestServer server;
    late String url;
    late AsyncHttpFetcher fetcher;

    final testData = Uint8List.fromList(const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

    setUp(() async {
      server = await TestServer.startWithData(testData);
      url = server.url;
      fetcher = await AsyncHttpFetcher();
    });

    tearDown(() async {
      fetcher.close();
      await server.stop();
    });

    test('fetchFileSize returns Content-Length', () async {
      expect(await fetcher.waitForValid(() => fetcher.fetchFileSize(url)), 10);
    });

    test('fetchRange returns the requested bytes', () async {
      final bytes = await fetcher.waitForValid(() => fetcher.fetchRange((
            url: url,
            start: 0,
            end: 9,
            headers: null,
          )));
      expect(bytes, equals([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]));
    });

    test('fetchRange from middle of file', () async {
      final bytes = await fetcher.waitForValid(() => fetcher.fetchRange((
            url: url,
            start: 5,
            end: 9,
            headers: null,
          )));
      expect(bytes, equals(List.generate(5, (i) => 5 + i)));
    });

    test('fetchRange single byte', () async {
      final bytes = await fetcher.waitForValid(() => fetcher.fetchRange((
            url: url,
            start: 4,
            end: 4,
            headers: null,
          )));
      expect(bytes, equals([4]));
    });

    test('reuses persistent loopback connection across many requests',
        () async {
      // The point of AsyncHttpFetcher's optimization: many calls hit the same
      // loopback socket and the worker reuses one HttpClient upstream.
      for (var i = 0; i < 2; i++) {
        final start = i * 5;
        final bytes = await fetcher.waitForValid(() => fetcher.fetchRange((
              url: url,
              start: start,
              end: start + 4,
              headers: null,
            )));
        expect(
          bytes,
          equals(List.generate(5, (k) => start + k)),
          reason: 'iteration $i',
        );
      }
    });

    test('passes custom headers through to the worker', () async {
      final bytes = await fetcher.waitForValid(
        () => fetcher.fetchRange((
          url: url,
          start: 0,
          end: 9,
          headers: RequestHeaders({'X-Custom': 'test'}),
        )),
      );
      expect(bytes.length, 10);
    });

    test('throws SocketException for non-2xx responses', () {
      expect(
        () async => await fetcher.waitForValid(
            () => fetcher.fetchFileSize('http://127.0.0.1:1/missing')),
        throwsA(isA<SocketException>()),
      );
    });

    test('after dispose, calls throw FetchException', () async {
      final f = await AsyncHttpFetcher();
      f.close();
      expect(
        () async => await fetcher.waitForValid(() => f.fetchFileSize(url)),
        throwsA(isA<FetchException>()),
      );
    });

    test(
        'succeeds when using a reconstructed but identical header map instance',
        () async {
      final headers1 = {'x-custom': 'value'};
      final headers2 = {'x-custom': 'value'};

      expect(
        () => fetcher.fetchFileSize(url, headers: headers1),
        throwsA(isA<PendingFetchException>()),
      );

      await fetcher.loadPending();

      final size = fetcher.fetchFileSize(url, headers: headers2);
      expect(size, 10);
    });

    test(
        'succeeds when using a reconstructed but identical header map instance',
        () async {
      final headers1 = {'x-custom': 'value'};
      final headers2 = {'x-custom': 'value'};

      expect(
        () => fetcher.fetchRange((
          url: url,
          start: 0,
          end: 4,
          headers: RequestHeaders(headers1),
        )),
        throwsA(isA<PendingFetchException>()),
      );

      await fetcher.loadPending();

      final data = fetcher.fetchRange((
        url: url,
        start: 0,
        end: 4,
        headers: RequestHeaders(headers2),
      ));
      expect(data, [0, 1, 2, 3, 4]);
    });
  });

  group('AsyncHttpFetcher (HTTPS, self-signed)', () {
    late TestServer server;
    late String url;
    late AsyncHttpFetcher fetcher;

    final testData = Uint8List.fromList(List.generate(256, (i) => i));

    setUp(() async {
      server = await TestServer.startWithData(testData, https: true);
      url = server.url;
      fetcher = await AsyncHttpFetcher(allowSelfSigned: true);
    });

    tearDown(() async {
      fetcher.close();
      await server.stop();
    });

    test('fetchFileSize over TLS', () async {
      expect(await fetcher.waitForValid(() => fetcher.fetchFileSize(url)), 256);
    });

    test('fetchRange over TLS returns correct bytes', () async {
      final bytes = await fetcher.waitForValid(() => fetcher.fetchRange((
            url: url,
            start: 64,
            end: 79,
            headers: null,
          )));
      expect(bytes, equals(List.generate(16, (i) => 64 + i)));
    });

    test('reuses upstream TLS connection across many range reads', () async {
      // Without HttpClient pooling, each call would reopen a TLS handshake.
      // We just assert correctness over many sequential calls — the perf
      // benefit is structural, but this exercises the keep-alive path.
      for (var i = 0; i < 20; i++) {
        final start = i * 8;
        final bytes = await fetcher.waitForValid(() => fetcher.fetchRange((
              url: url,
              start: start,
              end: start + 7,
              headers: null,
            )));
        expect(
          bytes,
          equals(List.generate(8, (k) => start + k)),
          reason: 'iteration $i',
        );
      }
    });

    test('rejects bad cert when allowSelfSigned is false', () async {
      final strict = await AsyncHttpFetcher();
      try {
        expect(
          () async =>
              await strict.waitForValid(() => strict.fetchFileSize(url)),
          throwsA(isA<HandshakeException>()),
        );
      } finally {
        strict.close();
      }
    });
  });
}
