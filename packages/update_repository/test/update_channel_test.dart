import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

void main() {
  group('normalizeUpdateChannel', () {
    test('keeps experimental (trimmed, case-insensitive)', () {
      expect(normalizeUpdateChannel('experimental'), 'experimental');
      expect(normalizeUpdateChannel(' Experimental\n'), 'experimental');
    });

    test('maps everything else to production', () {
      expect(normalizeUpdateChannel('production'), 'production');
      expect(normalizeUpdateChannel(''), 'production');
      expect(normalizeUpdateChannel('nightly'), 'production');
    });
  });
}
