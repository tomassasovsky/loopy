import 'package:flutter_test/flutter_test.dart';
import 'package:led_client/led_client.dart';

void main() {
  group('LedFrame.toBytes', () {
    test('serialises to the exact documented byte layout', () {
      const frame = LedFrame(
        running: true,
        global: LedGlobalColor.amber,
        loopLengthUs: 0x01020304,
        tracks: [LedTrackColor.green, LedTrackColor.red],
      );

      // [sync][type][len][flags][global][loopUs LE ×4][n][t0][t1][xor].
      // body = 1,3, 04,03,02,01, 2, 1,2  (len 9); xor over type..last = 0x0F.
      expect(frame.toBytes(), [
        0xA5, 0x01, 9, //
        0x01, 0x03, //
        0x04, 0x03, 0x02, 0x01, //
        0x02, 0x01, 0x02, //
        0x0F,
      ]);
    });

    test('clears the running flag when not running', () {
      expect(const LedFrame().toBytes()[3] & 0x1, 0x0);
      expect(const LedFrame(running: true).toBytes()[3] & 0x1, 0x1);
    });

    test('pingBytes is the fixed ping frame with a valid checksum', () {
      expect(LedFrame.pingBytes(), [
        LedFrame.sync,
        LedFrame.typePing,
        0,
        LedFrame.typePing,
      ]);
    });

    test('value equality ignores identity', () {
      const a = LedFrame(running: true, tracks: [LedTrackColor.green]);
      const b = LedFrame(running: true, tracks: [LedTrackColor.green]);
      const c = LedFrame(tracks: [LedTrackColor.green]);
      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
