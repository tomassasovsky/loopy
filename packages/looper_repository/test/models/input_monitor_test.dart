import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('InputMonitor', () {
    test('defaults to a disabled monitor routed to outs 0 + 1', () {
      const monitor = InputMonitor(input: 0);
      expect(monitor.input, 0);
      expect(monitor.enabled, isFalse);
      expect(monitor.outputMask, 0x3);
      expect(monitor.effects, isEmpty);
    });

    test('copyWith replaces only the given fields and keeps the input', () {
      const base = InputMonitor(input: 2);
      final updated = base.copyWith(
        enabled: true,
        outputMask: 0x1,
        effects: [TrackEffect(type: TrackEffectType.delay)],
      );
      expect(updated.input, 2);
      expect(updated.enabled, isTrue);
      expect(updated.outputMask, 0x1);
      expect(updated.effects.single.type, TrackEffectType.delay);

      // Omitted fields are preserved.
      expect(base.copyWith(enabled: true).outputMask, 0x3);
    });

    test('equality is value-based over all fields', () {
      final a = InputMonitor(
        input: 0,
        enabled: true,
        effects: [TrackEffect(type: TrackEffectType.drive)],
      );
      final b = InputMonitor(
        input: 0,
        enabled: true,
        effects: [TrackEffect(type: TrackEffectType.drive)],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const InputMonitor(input: 1, enabled: true)));
    });
  });
}
