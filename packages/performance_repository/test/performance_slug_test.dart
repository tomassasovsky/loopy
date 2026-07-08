import 'package:flutter_test/flutter_test.dart';
import 'package:performance_repository/performance_repository.dart';

void main() {
  group('performanceSlug', () {
    test('folds a timestamp into perf-YYYYMMDD-HHMMSS', () {
      expect(
        performanceSlug(DateTime(2026, 7, 6, 14, 30, 15)),
        'perf-20260706-143015',
      );
    });

    test('pads single-digit month/day/hour/minute/second', () {
      expect(
        performanceSlug(DateTime(2026, 1, 2, 3, 4, 5)),
        'perf-20260102-030405',
      );
    });
  });

  group('performanceCaptureSlug', () {
    test('keeps a clean name unchanged (idempotent for an existing slug)', () {
      expect(performanceCaptureSlug('My Take'), 'My Take');
      expect(
        performanceCaptureSlug(performanceCaptureSlug('My Take')!),
        'My Take',
      );
      expect(performanceCaptureSlug('take-2_final'), 'take-2_final');
    });

    test('trims and collapses internal whitespace', () {
      expect(performanceCaptureSlug('  spaced   out  '), 'spaced out');
    });

    test('turns disallowed characters into folded spaces', () {
      expect(performanceCaptureSlug('a/b:c'), 'a b c');
      expect(performanceCaptureSlug('Take #1 (loud)'), 'Take 1 loud');
    });

    test('two distinct inputs can fold to the same slug', () {
      expect(
        performanceCaptureSlug('My Take!'),
        performanceCaptureSlug('My Take'),
      );
      expect(performanceCaptureSlug('My Take!'), 'My Take');
    });

    test('rejects names that sanitize to nothing', () {
      expect(performanceCaptureSlug(''), isNull);
      expect(performanceCaptureSlug('   '), isNull);
      expect(performanceCaptureSlug('!!!'), isNull);
      expect(performanceCaptureSlug(r'/\:*'), isNull);
    });
  });
}
