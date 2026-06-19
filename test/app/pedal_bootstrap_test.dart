import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/app/pedal_bootstrap.dart';

void main() {
  group('createPedalRepository', () {
    test('returns null when there is no MIDI source', () {
      expect(createPedalRepository(null), isNull);
    });
  });
}
