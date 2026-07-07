import 'package:flutter_test/flutter_test.dart';
import 'package:performance_repository/performance_repository.dart';

void main() {
  group('UnfinalizedCapture', () {
    test('value equality and hashCode are by directory + slug', () {
      const a = UnfinalizedCapture(
        directory: '/exports/perf-1',
        slug: 'perf-1',
      );
      const b = UnfinalizedCapture(
        directory: '/exports/perf-1',
        slug: 'perf-1',
      );
      const c = UnfinalizedCapture(
        directory: '/exports/perf-2',
        slug: 'perf-2',
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
