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
}
