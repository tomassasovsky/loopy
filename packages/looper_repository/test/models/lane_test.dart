import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('Lane', () {
    test('defaults to an empty, input-less lane', () {
      const lane = Lane();
      expect(lane.inputChannel, -1);
      expect(lane.outputMask, 0x3);
      expect(lane.volume, 1);
      expect(lane.muted, isFalse);
      expect(lane.lengthFrames, 0);
      expect(lane.effects, isEmpty);
      expect(lane.hasContent, isFalse);
      expect(lane.inputMask, 0);
    });

    test('hasContent reflects recorded length', () {
      expect(const Lane(lengthFrames: 48000).hasContent, isTrue);
    });

    test('inputMask maps the recorded input channel to a bitmask', () {
      expect(const Lane(inputChannel: 0).inputMask, 0x1);
      expect(const Lane(inputChannel: 2).inputMask, 0x4);
      expect(const Lane().inputMask, 0); // -1 => nothing
    });

    test('equality is value-based over all fields', () {
      final a = Lane(
        inputChannel: 1,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      final b = Lane(
        inputChannel: 1,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      const c = Lane(inputChannel: 2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('maskToInputChannel', () {
    test('returns the index of the lowest set bit', () {
      expect(maskToInputChannel(0x1), 0);
      expect(maskToInputChannel(0x2), 1);
      expect(maskToInputChannel(0x6), 1); // bits 1 and 2 -> lowest is 1
    });

    test('returns -1 when no bit is set', () {
      expect(maskToInputChannel(0), -1);
    });
  });
}
