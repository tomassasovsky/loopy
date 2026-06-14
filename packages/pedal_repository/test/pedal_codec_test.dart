import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

import 'helpers/golden_frames.dart';
import 'helpers/sysex_builder.dart';

void main() {
  group('PedalCodec frame round-trip', () {
    for (final entry in goldenFrames().entries) {
      test('${entry.key} survives encode → decode', () {
        final bytes = PedalCodec.encodeFrame(entry.value);
        expect(PedalCodec.decodeFrame(bytes), entry.value);
      });
    }

    test('framing is F0…F7 and the payload is all 7-bit', () {
      for (final frame in goldenFrames().values) {
        final bytes = PedalCodec.encodeFrame(frame);
        expect(bytes.first, PedalCodec.sysExStart);
        expect(bytes.last, PedalCodec.sysExEnd);
        // Everything between the F0 and F7 status bytes must be < 0x80.
        final payload = bytes.sublist(1, bytes.length - 1);
        expect(payload, everyElement(lessThan(0x80)));
      }
    });

    test('preserves the maximum loop length', () {
      final frame = PedalStateFrame.blank().copyWith(
        loopLengthMicros: PedalStateFrame.maxLoopLengthMicros,
      );
      final decoded = PedalCodec.decodeFrame(PedalCodec.encodeFrame(frame));
      expect(decoded!.loopLengthMicros, PedalStateFrame.maxLoopLengthMicros);
    });

    test('matches the independent reference encoder', () {
      // Cross-check the production codec against the test-only packer.
      final frame = goldenFrames()['playing_bankb']!;
      final reference = buildStateSysEx([
        0x01, // flags: playMode
        GlobalColor.amber.index,
        1, // bank B
        4, // armed
        ...[1, 1, 1, 1, 0, 0, 0, 0], // green x4 then off
        0x60, 0xE3, 0x16, 0x00, // 1_500_000 µs LE
      ]);
      expect(PedalCodec.encodeFrame(frame), reference);
    });
  });

  group('PedalCodec.decodeMessage', () {
    test('decodes a NoteOn for every button as a press', () {
      for (final button in PedalButton.values) {
        expect(
          PedalCodec.decodeMessage(0x90, button.note, 100),
          ButtonPressed(button),
        );
      }
    });

    test('decodes a NoteOff for every button as a release', () {
      for (final button in PedalButton.values) {
        expect(
          PedalCodec.decodeMessage(0x80, button.note, 0),
          ButtonReleased(button),
        );
      }
    });

    test('treats a NoteOn with velocity 0 as a release', () {
      expect(
        PedalCodec.decodeMessage(0x90, PedalButton.recPlay.note, 0),
        const ButtonReleased(PedalButton.recPlay),
      );
    });

    test('attaches the supplied timestamp to button events', () {
      const ts = Duration(milliseconds: 42);
      expect(
        PedalCodec.decodeMessage(
          0x90,
          PedalButton.mode.note,
          64,
          timestamp: ts,
        ),
        const ButtonPressed(PedalButton.mode, timestamp: ts),
      );
      expect(
        PedalCodec.decodeMessage(
          0x80,
          PedalButton.mode.note,
          0,
          timestamp: ts,
        ),
        const ButtonReleased(PedalButton.mode, timestamp: ts),
      );
    });

    test('ignores the MIDI channel nibble', () {
      expect(
        PedalCodec.decodeMessage(0x9F, PedalButton.stop.note, 100),
        const ButtonPressed(PedalButton.stop),
      );
      expect(
        PedalCodec.decodeMessage(0x8A, PedalButton.stop.note, 0),
        const ButtonReleased(PedalButton.stop),
      );
    });

    test('returns null for a note that is not a pedal button', () {
      expect(PedalCodec.decodeMessage(0x90, 100, 100), isNull);
      expect(PedalCodec.decodeMessage(0x80, 100, 0), isNull);
    });

    group('encoder', () {
      test('decodes a positive relative turn', () {
        expect(
          PedalCodec.decodeMessage(0xB0, PedalCodec.encoderCc, 65),
          const EncoderDelta(1),
        );
      });

      test('decodes a negative relative turn', () {
        expect(
          PedalCodec.decodeMessage(0xB0, PedalCodec.encoderCc, 63),
          const EncoderDelta(-1),
        );
      });

      test('decodes the rest position as zero', () {
        expect(
          PedalCodec.decodeMessage(0xB0, PedalCodec.encoderCc, 64),
          const EncoderDelta(0),
        );
      });

      test('ignores an unrelated CC number', () {
        expect(
          PedalCodec.decodeMessage(0xB0, PedalCodec.encoderCc + 1, 65),
          isNull,
        );
      });
    });

    test('returns null for an unhandled status byte', () {
      expect(PedalCodec.decodeMessage(0xE0, 0, 0), isNull); // pitch bend
      expect(PedalCodec.decodeMessage(0xC0, 0, 0), isNull); // program change
    });
  });

  group('PedalCodec.encodeEncoder', () {
    test('is the inverse of the encoder decode', () {
      for (var delta = -64; delta <= 63; delta++) {
        final value = PedalCodec.encodeEncoder(delta);
        expect(value, inInclusiveRange(0, 127));
        expect(
          PedalCodec.decodeMessage(0xB0, PedalCodec.encoderCc, value),
          EncoderDelta(delta),
        );
      }
    });

    test('clamps out-of-range deltas to the representable bounds', () {
      expect(PedalCodec.encodeEncoder(1000), PedalCodec.encodeEncoder(63));
      expect(PedalCodec.encodeEncoder(-1000), PedalCodec.encodeEncoder(-64));
    });
  });

  group('PedalCodec.decodeFrame rejects malformed input', () {
    test('a message that is too short', () {
      expect(PedalCodec.decodeFrame(const [0xF0, 0xF7]), isNull);
    });

    test('a missing SysEx start byte', () {
      final bytes = buildStateSysEx(validPayload())..[0] = 0x00;
      expect(PedalCodec.decodeFrame(bytes), isNull);
    });

    test('a missing SysEx end byte', () {
      final bytes = buildStateSysEx(validPayload());
      bytes[bytes.length - 1] = 0x00;
      expect(PedalCodec.decodeFrame(bytes), isNull);
    });

    test('the wrong manufacturer id', () {
      expect(
        PedalCodec.decodeFrame(
          buildStateSysEx(validPayload(), manufacturer: 0x7E),
        ),
        isNull,
      );
    });

    test('an unrecognized protocol version', () {
      expect(
        PedalCodec.decodeFrame(buildStateSysEx(validPayload(), version: 0x02)),
        isNull,
      );
    });

    test('an unrecognized message type', () {
      expect(
        PedalCodec.decodeFrame(buildStateSysEx(validPayload(), type: 0x7F)),
        isNull,
      );
    });

    test('a corrupted checksum', () {
      final bytes = buildStateSysEx(validPayload());
      bytes[bytes.length - 2] ^= 0x7F; // flip the checksum byte
      expect(PedalCodec.decodeFrame(bytes), isNull);
    });

    test('a payload byte with the 8th bit set (checksum still valid)', () {
      final packed = pack7(validPayload());
      packed[3] |= 0x80; // smuggle in an 8th bit, then re-checksum
      expect(PedalCodec.decodeFrame(buildFromPacked(packed)), isNull);
    });

    test('a payload of the wrong logical length', () {
      // 14 logical bytes unpack to 14, not 16.
      expect(
        PedalCodec.decodeFrame(buildStateSysEx(List<int>.filled(14, 0))),
        isNull,
      );
    });

    test('an out-of-range global color index', () {
      final payload = validPayload()..[1] = GlobalColor.values.length;
      expect(PedalCodec.decodeFrame(buildStateSysEx(payload)), isNull);
    });

    test('an out-of-range active bank', () {
      final payload = validPayload()..[2] = 2;
      expect(PedalCodec.decodeFrame(buildStateSysEx(payload)), isNull);
    });

    test('an out-of-range armed track', () {
      final payload = validPayload()..[3] = PedalStateFrame.trackCount;
      expect(PedalCodec.decodeFrame(buildStateSysEx(payload)), isNull);
    });

    test('an out-of-range track LED index', () {
      final payload = validPayload()..[4] = PedalTrackLed.values.length;
      expect(PedalCodec.decodeFrame(buildStateSysEx(payload)), isNull);
    });
  });
}
