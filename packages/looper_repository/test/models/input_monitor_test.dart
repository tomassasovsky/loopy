import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('InputMonitor', () {
    test('defaults to a disabled monitor with a clean single chain', () {
      const monitor = InputMonitor(input: 0);
      expect(monitor.input, 0);
      expect(monitor.enabled, isFalse);
      expect(monitor.outputMask, 0x3);
      expect(monitor.volume, 1.0);
      expect(monitor.muted, isFalse);
      expect(monitor.effects, isEmpty);
    });

    test('copyWith replaces only the given fields and keeps the input', () {
      const base = InputMonitor(input: 2);
      final updated = base.copyWith(
        enabled: true,
        outputMask: 0x1,
        volume: 0.5,
        muted: true,
        effects: [TrackEffect(type: TrackEffectType.delay)],
      );
      expect(updated.input, 2);
      expect(updated.enabled, isTrue);
      expect(updated.outputMask, 0x1);
      expect(updated.volume, 0.5);
      expect(updated.muted, isTrue);
      expect(updated.effects.single.type, TrackEffectType.delay);

      // Omitted fields are preserved.
      final onlyEnabled = base.copyWith(enabled: true);
      expect(onlyEnabled.outputMask, 0x3);
      expect(onlyEnabled.volume, 1.0);
      expect(onlyEnabled.muted, isFalse);
      expect(onlyEnabled.effects, isEmpty);
    });

    test('equality is value-based over all fields', () {
      const a = InputMonitor(
        input: 0,
        enabled: true,
        outputMask: 0x1,
        volume: 0.5,
        muted: true,
      );
      const b = InputMonitor(
        input: 0,
        enabled: true,
        outputMask: 0x1,
        volume: 0.5,
        muted: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const InputMonitor(input: 1, enabled: true)));
      expect(
        a,
        isNot(const InputMonitor(input: 0, enabled: true, outputMask: 0x2)),
      );
    });

    test('the effect chain participates in equality', () {
      final withFx = InputMonitor(
        input: 0,
        effects: [TrackEffect(type: TrackEffectType.drive)],
      );
      final withOtherFx = InputMonitor(
        input: 0,
        effects: [TrackEffect(type: TrackEffectType.delay)],
      );
      expect(withFx, isNot(const InputMonitor(input: 0))); // vs clean chain
      expect(withFx, isNot(withOtherFx)); // a differing chain breaks equality
    });
  });
}
