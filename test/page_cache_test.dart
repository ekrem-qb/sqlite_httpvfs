import 'dart:typed_data';

import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
import 'package:test/test.dart';

void main() {
  group('LruPageCache', () {
    late LruPageCache cache;

    setUp(() {
      cache = LruPageCache(maxPages: 4, pageSize: 16);
    });

    test('returns null on cache miss', () {
      expect(cache.get(0), isNull);
      expect(cache.misses, 1);
    });

    test('stores and retrieves a page', () {
      final data = Uint8List.fromList(List.generate(16, (i) => i));
      cache.put(0, data);
      final result = cache.get(0);
      expect(result, equals(data));
      expect(cache.hits, 1);
    });

    test('stores multiple pages', () {
      for (var i = 0; i < 4; i++) {
        cache.put(i * 16, Uint8List.fromList(List.filled(16, i)));
      }
      expect(cache.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(
            cache.get(i * 16), equals(Uint8List.fromList(List.filled(16, i))));
      }
    });

    test('evicts LRU page when at capacity', () {
      // Fill cache: pages at offsets 0, 16, 32, 48
      for (var i = 0; i < 4; i++) {
        cache.put(i * 16, Uint8List.fromList(List.filled(16, i)));
      }

      // Insert 5th page → should evict offset 0 (LRU)
      cache.put(64, Uint8List.fromList(List.filled(16, 99)));

      expect(cache.length, 4);
      expect(cache.get(0), isNull); // evicted
      expect(cache.get(64), isNotNull); // present
    });

    test('access refreshes LRU position', () {
      // Fill cache
      for (var i = 0; i < 4; i++) {
        cache.put(i * 16, Uint8List.fromList(List.filled(16, i)));
      }

      // Access offset 0 → moves it to most-recently-used
      cache.get(0);

      // Insert 5th page → should evict offset 16 (now LRU), not offset 0
      cache.put(64, Uint8List.fromList(List.filled(16, 99)));

      expect(cache.get(0), isNotNull); // still present (was accessed)
      expect(cache.get(16), isNull); // evicted (was LRU)
    });

    test('putBulk splits data into pages', () {
      // 48 bytes = 3 pages of 16 bytes each
      final data = Uint8List.fromList(List.generate(48, (i) => i));
      cache.putBulk(0, data);

      expect(cache.length, 3);
      expect(cache.get(0), equals(Uint8List.fromList(data.sublist(0, 16))));
      expect(cache.get(16), equals(Uint8List.fromList(data.sublist(16, 32))));
      expect(cache.get(32), equals(Uint8List.fromList(data.sublist(32, 48))));
    });

    test('putBulk handles partial trailing page', () {
      // 20 bytes = 1 full page (16) + 1 partial page (4)
      final data = Uint8List.fromList(List.generate(20, (i) => i));
      cache.putBulk(0, data);

      expect(cache.length, 2);
      expect(cache.get(0)!.length, 16);
      expect(cache.get(16)!.length, 4);
    });

    test('putBulk with non-zero start offset', () {
      final data = Uint8List.fromList(List.generate(32, (i) => i + 100));
      cache.putBulk(48, data);

      expect(cache.get(48), isNotNull);
      expect(cache.get(64), isNotNull);
      expect(cache.get(0), isNull); // not cached
    });

    test('clear removes all pages and resets stats', () {
      cache.put(0, Uint8List(16));
      cache.get(0);
      cache.get(99); // miss
      cache.clear();

      expect(cache.length, 0);
      expect(cache.hits, 0);
      expect(cache.misses, 0);
    });

    test('totalBytes tracks cached data size', () {
      cache.put(0, Uint8List(16));
      cache.put(16, Uint8List(16));
      expect(cache.totalBytes, 32);

      // Partial page
      cache.put(32, Uint8List(8));
      expect(cache.totalBytes, 40);
    });

    test('containsPage does not affect LRU order', () {
      for (var i = 0; i < 4; i++) {
        cache.put(i * 16, Uint8List.fromList(List.filled(16, i)));
      }

      // containsPage should NOT refresh offset 0
      expect(cache.containsPage(0), isTrue);
      expect(cache.containsPage(999), isFalse);

      // Insert 5th → should still evict offset 0 (containsPage didn't refresh)
      cache.put(64, Uint8List.fromList(List.filled(16, 99)));
      expect(cache.containsPage(0), isFalse);
    });
  });
}
