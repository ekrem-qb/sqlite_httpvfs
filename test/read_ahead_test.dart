import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
import 'package:test/test.dart';

void main() {
  group('ReadAheadStrategy', () {
    late ReadAheadStrategy strategy;
    const pageSize = 4096;
    const fileSize = 1024 * 1024; // 1 MB

    setUp(() {
      strategy = ReadAheadStrategy(
        maxReadAheadPages: 8,
        pageSize: pageSize,
      );
    });

    test('single read returns requested range only', () {
      final result = strategy.plan(0, pageSize, fileSize);
      expect(result.fetchStart, 0);
      expect(result.fetchEnd, pageSize - 1);
    });

    test('no expansion before threshold', () {
      // Read 0 (first read, no history)
      var r = strategy.plan(0, pageSize, fileSize);
      expect(r.fetchEnd, pageSize - 1);

      // Read 1 (sequential, but sequentialHits=1, threshold=2)
      r = strategy.plan(pageSize, pageSize, fileSize);
      expect(r.fetchEnd, 2 * pageSize - 1);
    });

    test('expands after threshold sequential reads', () {
      // Read 0, 1, 2 (3 sequential reads → sequentialHits reaches threshold)
      strategy.plan(0, pageSize, fileSize);
      strategy.plan(pageSize, pageSize, fileSize);
      final r = strategy.plan(2 * pageSize, pageSize, fileSize);

      // After threshold: 1 extra page
      expect(r.fetchEnd, 3 * pageSize + pageSize - 1);
    });

    test('exponential growth of read-ahead', () {
      // Simulate many sequential reads
      for (var i = 0; i < 6; i++) {
        final r = strategy.plan(i * pageSize, pageSize, fileSize);
        if (i >= readAheadThreshold) {
          // After threshold, should expand beyond the requested page
          expect(r.fetchEnd, greaterThan((i + 1) * pageSize - 1),
              reason: 'read $i should trigger read-ahead');
        }
      }
    });

    test('read-ahead capped at maxReadAheadPages', () {
      // Do many sequential reads to max out
      for (var i = 0; i < 20; i++) {
        strategy.plan(i * pageSize, pageSize, fileSize);
      }

      final r = strategy.plan(20 * pageSize, pageSize, fileSize);
      // Max read-ahead = 8 pages
      final maxEnd = (20 + 1) * pageSize + 8 * pageSize - 1;
      expect(r.fetchEnd, lessThanOrEqualTo(maxEnd));
    });

    test('non-sequential read resets counter', () {
      // Build up sequential reads
      strategy.plan(0, pageSize, fileSize);
      strategy.plan(pageSize, pageSize, fileSize);
      strategy.plan(2 * pageSize, pageSize, fileSize);
      expect(strategy.sequentialHits, greaterThanOrEqualTo(2));

      // Jump to a non-sequential offset
      strategy.plan(100 * pageSize, pageSize, fileSize);
      expect(strategy.sequentialHits, 0);

      // Next read should not expand
      final r = strategy.plan(101 * pageSize, pageSize, fileSize);
      expect(r.fetchEnd, 102 * pageSize - 1);
    });

    test('clamps to file size', () {
      // Read near end of file with read-ahead
      final nearEnd = fileSize - pageSize;

      // Build sequential pattern
      strategy.plan(nearEnd - 3 * pageSize, pageSize, fileSize);
      strategy.plan(nearEnd - 2 * pageSize, pageSize, fileSize);
      strategy.plan(nearEnd - pageSize, pageSize, fileSize);

      final r = strategy.plan(nearEnd, pageSize, fileSize);
      // Should not exceed fileSize
      expect(r.fetchEnd, lessThan(fileSize));
    });

    test('aligns fetchStart to page boundary', () {
      // Read from mid-page offset
      final r = strategy.plan(pageSize + 100, 50, fileSize);
      expect(r.fetchStart, pageSize); // aligned to page
    });

    test('reset clears state', () {
      strategy.plan(0, pageSize, fileSize);
      strategy.plan(pageSize, pageSize, fileSize);
      strategy.plan(2 * pageSize, pageSize, fileSize);

      strategy.reset();
      expect(strategy.sequentialHits, 0);

      // After reset, first read should not expand
      final r = strategy.plan(0, pageSize, fileSize);
      expect(r.fetchEnd, pageSize - 1);
    });
  });
}
