import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

void main() {
  group('EngineResult.fromCode', () {
    test('maps each known code', () {
      expect(EngineResult.fromCode(0), EngineResult.ok);
      expect(EngineResult.fromCode(-1), EngineResult.invalid);
      expect(EngineResult.fromCode(-2), EngineResult.alreadyRunning);
      expect(EngineResult.fromCode(-3), EngineResult.notRunning);
      expect(EngineResult.fromCode(-4), EngineResult.device);
    });

    test('maps unknown codes to invalid', () {
      expect(EngineResult.fromCode(42), EngineResult.invalid);
      expect(EngineResult.fromCode(-99), EngineResult.invalid);
    });
  });

  group('EngineResult.isOk', () {
    test('is true only for ok', () {
      expect(EngineResult.ok.isOk, isTrue);
      for (final result in EngineResult.values.where(
        (r) => r != EngineResult.ok,
      )) {
        expect(result.isOk, isFalse, reason: '${result.name} should not be ok');
      }
    });
  });

  group('EngineException', () {
    test('toString includes the result name', () {
      const exception = EngineException(EngineResult.device);
      expect(exception.toString(), contains('device'));
    });

    test('toString includes an optional message', () {
      const exception = EngineException(EngineResult.invalid, 'bad handle');
      expect(exception.toString(), contains('bad handle'));
    });
  });
}
