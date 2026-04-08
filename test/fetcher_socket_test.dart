import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
import 'package:test/test.dart';

import 'test_server.dart';

void main() {
  group('SocketFetcher', () {
    late TestServer server;
    late String url;
    late SocketFetcher fetcher;

    // Test data: 256 bytes, each byte = its index
    final testData = List.generate(256, (i) => i);

    setUp(() async {
      server = await TestServer.startWithData(testData);
      url = server.url;
      fetcher = SocketFetcher();
    });

    tearDown(() async {
      await server.stop();
    });

    test('fetchFileSize returns correct Content-Length', () {
      final size = fetcher.fetchFileSize(url);
      expect(size, 256);
    });

    test('fetchRange returns requested bytes', () {
      final bytes = fetcher.fetchRange(url, 0, 9);
      expect(bytes.length, 10);
      expect(bytes, equals([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]));
    });

    test('fetchRange from middle of file', () {
      final bytes = fetcher.fetchRange(url, 100, 109);
      expect(bytes.length, 10);
      expect(bytes, equals([100, 101, 102, 103, 104, 105, 106, 107, 108, 109]));
    });

    test('fetchRange up to end of file', () {
      final bytes = fetcher.fetchRange(url, 250, 255);
      expect(bytes.length, 6);
      expect(bytes, equals([250, 251, 252, 253, 254, 255]));
    });

    test('fetchRange single byte', () {
      final bytes = fetcher.fetchRange(url, 42, 42);
      expect(bytes.length, 1);
      expect(bytes.first, 42);
    });

    test('throws FetchException on HTTPS URL', () {
      expect(
        () => fetcher.fetchRange('https://example.com/test', 0, 10),
        throwsA(isA<FetchException>()),
      );
    });

    test('passes custom headers without error', () {
      final bytes = fetcher.fetchRange(
        url,
        0,
        9,
        headers: {'X-Custom': 'test-value'},
      );
      expect(bytes.length, 10);
    });
  });

  group('CurlFetcher', () {
    late TestServer server;
    late String url;
    late CurlFetcher fetcher;

    final testData = List.generate(256, (i) => i);

    setUp(() async {
      server = await TestServer.startWithData(testData);
      url = server.url;
      fetcher = CurlFetcher();
    });

    tearDown(() async {
      await server.stop();
    });

    test('fetchFileSize returns correct Content-Length', () {
      final size = fetcher.fetchFileSize(url);
      expect(size, 256);
    });

    test('fetchRange returns requested bytes', () {
      final bytes = fetcher.fetchRange(url, 0, 9);
      expect(bytes.length, 10);
      expect(bytes, equals([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]));
    });

    test('fetchRange from middle of file', () {
      final bytes = fetcher.fetchRange(url, 100, 109);
      expect(bytes.length, 10);
      expect(bytes, equals([100, 101, 102, 103, 104, 105, 106, 107, 108, 109]));
    });
  });

  group('createFetcher', () {
    test('picks SocketFetcher for http://', () {
      final f = createFetcher('http://localhost:8080/test.db');
      expect(f, isA<SocketFetcher>());
    });

    test('picks CurlFetcher for https://', () {
      final f = createFetcher('https://example.com/test.db');
      expect(f, isA<CurlFetcher>());
    });
  });
}
