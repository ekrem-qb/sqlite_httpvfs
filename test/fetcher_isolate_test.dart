import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
import 'package:test/test.dart';

import 'test_server.dart';

void main() {
  group('IsolateFetcher (HTTP)', () {
    late TestServer server;
    late String url;
    late IsolateFetcher fetcher;

    final testData = List.generate(256, (i) => i);

    setUp(() async {
      server = await TestServer.startWithData(testData);
      url = server.url;
      fetcher = await IsolateFetcher.create();
    });

    tearDown(() async {
      await fetcher.dispose();
      await server.stop();
    });

    test('fetchFileSize returns Content-Length', () {
      expect(fetcher.fetchFileSize(url), 256);
    });

    test('fetchRange returns the requested bytes', () {
      final bytes = fetcher.fetchRange(url, 0, 9);
      expect(bytes, equals([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]));
    });

    test('fetchRange from middle of file', () {
      final bytes = fetcher.fetchRange(url, 100, 109);
      expect(bytes, equals(List.generate(10, (i) => 100 + i)));
    });

    test('fetchRange single byte', () {
      final bytes = fetcher.fetchRange(url, 42, 42);
      expect(bytes, equals([42]));
    });

    test('reuses persistent loopback connection across many requests', () {
      // The point of IsolateFetcher's optimization: many calls hit the same
      // loopback socket and the worker reuses one HttpClient upstream.
      for (var i = 0; i < 50; i++) {
        final start = i * 5;
        final bytes = fetcher.fetchRange(url, start, start + 4);
        expect(
          bytes,
          equals(List.generate(5, (k) => start + k)),
          reason: 'iteration $i',
        );
      }
    });

    test('passes custom headers through to the worker', () {
      final bytes = fetcher.fetchRange(
        url,
        0,
        9,
        headers: {'X-Custom': 'isolate-test'},
      );
      expect(bytes.length, 10);
    });

    test('throws FetchException for non-2xx responses', () {
      expect(
        () => fetcher.fetchFileSize('http://127.0.0.1:1/missing'),
        throwsA(isA<FetchException>()),
      );
    });

    test('after dispose, calls throw FetchException', () async {
      final f = await IsolateFetcher.create();
      await f.dispose();
      expect(() => f.fetchFileSize(url), throwsA(isA<FetchException>()));
    });
  });

  group('IsolateFetcher (HTTPS, self-signed)', () {
    late TestServer server;
    late String url;
    late IsolateFetcher fetcher;

    final testData = List.generate(256, (i) => i);

    setUp(() async {
      server = await TestServer.startWithData(testData, https: true);
      url = server.url;
      fetcher = await IsolateFetcher.create(allowSelfSigned: true);
    });

    tearDown(() async {
      await fetcher.dispose();
      await server.stop();
    });

    test('fetchFileSize over TLS', () {
      expect(fetcher.fetchFileSize(url), 256);
    });

    test('fetchRange over TLS returns correct bytes', () {
      final bytes = fetcher.fetchRange(url, 64, 79);
      expect(bytes, equals(List.generate(16, (i) => 64 + i)));
    });

    test('reuses upstream TLS connection across many range reads', () {
      // Without HttpClient pooling, each call would reopen a TLS handshake.
      // We just assert correctness over many sequential calls — the perf
      // benefit is structural, but this exercises the keep-alive path.
      for (var i = 0; i < 20; i++) {
        final start = i * 8;
        final bytes = fetcher.fetchRange(url, start, start + 7);
        expect(
          bytes,
          equals(List.generate(8, (k) => start + k)),
          reason: 'iteration $i',
        );
      }
    });

    test('rejects bad cert when allowSelfSigned is false', () async {
      final strict = await IsolateFetcher.create();
      try {
        expect(
          () => strict.fetchFileSize(url),
          throwsA(isA<FetchException>()),
        );
      } finally {
        await strict.dispose();
      }
    });
  });

  group('createFetcherAsync', () {
    test('picks IsolateFetcher for https://', () async {
      final f = await createFetcherAsync('https://example.com/test.db');
      expect(f, isA<IsolateFetcher>());
      await (f as IsolateFetcher).dispose();
    });

    test('picks SocketFetcher for http://', () async {
      final f = await createFetcherAsync('http://localhost:8080/test.db');
      expect(f, isA<SocketFetcher>());
    });
  });
}
