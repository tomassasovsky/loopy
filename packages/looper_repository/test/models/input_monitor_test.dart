import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('MonitorLane', () {
    test('defaults to full stereo output, unity, unmuted, no effects', () {
      const lane = MonitorLane();
      expect(lane.outputMask, 0x3);
      expect(lane.volume, 1.0);
      expect(lane.muted, isFalse);
      expect(lane.effects, isEmpty);
    });

    test('copyWith replaces only the given fields', () {
      const base = MonitorLane();
      final updated = base.copyWith(
        outputMask: 0x1,
        volume: 0.5,
        muted: true,
        effects: [TrackEffect(type: TrackEffectType.delay)],
      );
      expect(updated.outputMask, 0x1);
      expect(updated.volume, 0.5);
      expect(updated.muted, isTrue);
      expect(updated.effects.single.type, TrackEffectType.delay);

      // Omitted fields are preserved.
      expect(base.copyWith(muted: true).outputMask, 0x3);
      expect(base.copyWith(muted: true).volume, 1.0);
      expect(base.copyWith(muted: true).effects, isEmpty);
    });

    test('equality is value-based over all fields', () {
      const a = MonitorLane(outputMask: 0x1, volume: 0.5, muted: true);
      const b = MonitorLane(outputMask: 0x1, volume: 0.5, muted: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MonitorLane(outputMask: 0x2, volume: 0.5)));
      expect(a, isNot(const MonitorLane(outputMask: 0x1, volume: 0.5)));
    });

    test('the effect chain participates in equality', () {
      final withFx = MonitorLane(
        effects: [TrackEffect(type: TrackEffectType.drive)],
      );
      final withOtherFx = MonitorLane(
        effects: [TrackEffect(type: TrackEffectType.delay)],
      );
      expect(withFx, isNot(const MonitorLane())); // vs. the clean lane
      expect(withFx, isNot(withOtherFx)); // a differing chain breaks equality
    });
  });

  group('InputMonitor', () {
    test('defaults to a disabled monitor with one default lane', () {
      const monitor = InputMonitor(input: 0);
      expect(monitor.input, 0);
      expect(monitor.enabled, isFalse);
      expect(monitor.laneCount, 1);
      expect(monitor.lanes.single, const MonitorLane());
    });

    test('lane(i) returns the lane, or a default when out of range', () {
      const monitor = InputMonitor(
        input: 0,
        lanes: [MonitorLane(outputMask: 0x1)],
      );
      expect(monitor.lane(0).outputMask, 0x1);
      expect(monitor.lane(1), const MonitorLane());
      expect(monitor.lane(-1), const MonitorLane());
    });

    test('copyWith replaces only the given fields and keeps the input', () {
      const base = InputMonitor(input: 2);
      final updated = base.copyWith(
        enabled: true,
        lanes: const [MonitorLane(outputMask: 0x1), MonitorLane()],
      );
      expect(updated.input, 2);
      expect(updated.enabled, isTrue);
      expect(updated.laneCount, 2);

      // Omitted fields are preserved.
      expect(base.copyWith(enabled: true).lanes.single, const MonitorLane());
    });

    test('withLane replaces one lane immutably without touching siblings', () {
      const base = InputMonitor(
        input: 0,
        lanes: [MonitorLane(outputMask: 0x1), MonitorLane(outputMask: 0x2)],
      );
      final next = base.withLane(1, const MonitorLane(outputMask: 0x4));
      expect(next.lane(0).outputMask, 0x1); // sibling untouched
      expect(next.lane(1).outputMask, 0x4);
      // The original is unchanged (immutability).
      expect(base.lane(1).outputMask, 0x2);
      expect(identical(base.lanes, next.lanes), isFalse);
    });

    test('withLane grows the list with defaults past the end', () {
      const base = InputMonitor(input: 0);
      final next = base.withLane(2, const MonitorLane(outputMask: 0x4));
      expect(next.laneCount, 3);
      expect(next.lane(0), const MonitorLane());
      expect(next.lane(1), const MonitorLane());
      expect(next.lane(2).outputMask, 0x4);
    });

    test('equality is value-based over all fields', () {
      const a = InputMonitor(
        input: 0,
        enabled: true,
        lanes: [MonitorLane(volume: 0.5)],
      );
      const b = InputMonitor(
        input: 0,
        enabled: true,
        lanes: [MonitorLane(volume: 0.5)],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const InputMonitor(input: 1, enabled: true)));
      // A differing lane (default vs volume 0.5) breaks equality.
      expect(a, isNot(const InputMonitor(input: 0, enabled: true)));
    });
  });
}
