import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('InputMonitor', () {
    test('defaults to a disabled monitor routed to outs 0 + 1, no dry', () {
      const monitor = InputMonitor(input: 0);
      expect(monitor.input, 0);
      expect(monitor.enabled, isFalse);
      expect(monitor.outputMask, 0x3);
      expect(monitor.dryOutputMask, 0);
      expect(monitor.volume, 1.0);
      expect(monitor.effects, isEmpty);
    });

    test('copyWith replaces only the given fields and keeps the input', () {
      const base = InputMonitor(input: 2);
      final updated = base.copyWith(
        enabled: true,
        outputMask: 0x1,
        dryOutputMask: 0x2,
        volume: 0.5,
        effects: [TrackEffect(type: TrackEffectType.delay)],
      );
      expect(updated.input, 2);
      expect(updated.enabled, isTrue);
      expect(updated.outputMask, 0x1);
      expect(updated.dryOutputMask, 0x2);
      expect(updated.volume, 0.5);
      expect(updated.effects.single.type, TrackEffectType.delay);

      // Omitted fields are preserved.
      expect(base.copyWith(enabled: true).outputMask, 0x3);
      expect(base.copyWith(enabled: true).dryOutputMask, 0);
      expect(base.copyWith(enabled: true).volume, 1.0);
    });

    test('the dry-send mask participates in equality', () {
      expect(
        const InputMonitor(input: 0, dryOutputMask: 0x2),
        isNot(const InputMonitor(input: 0)),
      );
    });

    test('the volume participates in equality', () {
      expect(
        const InputMonitor(input: 0, volume: 0.5),
        isNot(const InputMonitor(input: 0)),
      );
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
