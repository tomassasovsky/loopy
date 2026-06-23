import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('LooperState', () {
    test('defaults to all outputs enabled', () {
      const state = LooperState();
      expect(state.outputEnabledMask, 0xFFFFFFFF);
      expect(state.isOutputEnabled(0), isTrue);
      expect(state.isOutputEnabled(7), isTrue);
    });

    test('isOutputEnabled reads the gate bit (beyond-range reads enabled)', () {
      const state = LooperState(outputEnabledMask: 0x1); // only output 0 on
      expect(state.isOutputEnabled(0), isTrue);
      expect(state.isOutputEnabled(1), isFalse);
      // A negative / out-of-range index never reports "disabled".
      expect(state.isOutputEnabled(-1), isTrue);
    });

    test('outputEnabledMask participates in equality (props rigor)', () {
      const a = LooperState();
      const b = LooperState(outputEnabledMask: 0x1);
      expect(a, isNot(equals(b)));
      expect(a, equals(const LooperState()));
      expect(a.hashCode, const LooperState().hashCode);
    });
  });
}
