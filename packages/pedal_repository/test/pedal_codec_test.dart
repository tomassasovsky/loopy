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
      final reference = buildStateSysEx(
        [
          0x01, // flags: mode=play (looperMode=multi/countingIn=false, both
          // default, contribute nothing to bits4-7)
          GlobalColor.amber.index,
          1, // bank B
          4, // armed
          ...[1, 1, 1, 1, 0, 0, 0, 0], // green x4 then off
          0x60, 0xE3, 0x16, 0x00, // 1_500_000 µs LE
          153, // master gain 153/255
        ],
        version: PedalCodec.protocolVersionV2,
      );
      expect(PedalCodec.encodeFrame(frame), reference);
    });
  });

  group('PedalCodec.performanceArmed flag (D-PEDAL)', () {
    test('round-trips independently of the other flag bits', () {
      final frame = PedalStateFrame.blank().copyWith(
        performanceArmed: true,
        clearFadeActive: true,
        mode: PedalMode.play,
      );
      final decoded = PedalCodec.decodeFrame(PedalCodec.encodeFrame(frame));
      expect(decoded!.performanceArmed, isTrue);
      expect(decoded.clearFadeActive, isTrue);
      expect(decoded.mode, PedalMode.play);
    });

    test('decodes performanceArmed back out', () {
      final frame = PedalStateFrame.blank().copyWith(performanceArmed: true);
      final decoded = PedalCodec.decodeFrame(PedalCodec.encodeFrame(frame));
      expect(decoded!.performanceArmed, isTrue);
    });

    test(
      'an old-firmware-shaped frame (bit3 unset) decodes with '
      'performanceArmed false',
      () {
        // A frame built exactly as pre-D-PEDAL firmware would have sent it —
        // flags byte carries only mode/clearFadeActive/goodbye, bit3 never
        // set. Proves a pedal running old firmware still decodes cleanly.
        final oldStyle = buildStateSysEx([
          0x00, // flags: rec mode, no clear fade, not goodbye
          GlobalColor.green.index,
          0,
          0,
          ...List.filled(8, 0),
          0, 0, 0, 0,
        ]);
        final decoded = PedalCodec.decodeFrame(oldStyle);
        expect(decoded, isNotNull);
        expect(decoded!.performanceArmed, isFalse);
      },
    );
  });

  group('PedalCodec protocol v2: looperMode + countingIn (D11)', () {
    test('protocolVersion (the encode default) is v2', () {
      expect(PedalCodec.protocolVersion, PedalCodec.protocolVersionV2);
    });

    test('encodeFrame emits protocolVersionV2 by default', () {
      final bytes = PedalCodec.encodeFrame(PedalStateFrame.blank());
      expect(bytes[2], PedalCodec.protocolVersionV2);
    });

    test('looperMode and countingIn round-trip at v2', () {
      final frame = goldenFrames()['mode_counting_in']!;
      final decoded = PedalCodec.decodeFrame(PedalCodec.encodeFrame(frame));
      expect(decoded!.looperMode, PedalLooperMode.sync);
      expect(decoded.countingIn, isTrue);
    });

    test(
      'every PedalLooperMode value round-trips through the real encode -> '
      'decode path (not just sync/song/band, which fit in 2 bits and would '
      'hide a `& 0x03` vs `& 0x07` mask bug -- free needs bit 6 too)',
      () {
        for (final mode in PedalLooperMode.values) {
          final frame = PedalStateFrame.blank().copyWith(
            looperMode: mode,
            countingIn: true,
          );
          final decoded = PedalCodec.decodeFrame(PedalCodec.encodeFrame(frame));
          expect(
            decoded!.looperMode,
            mode,
            reason: 'PedalLooperMode.$mode did not round-trip',
          );
          expect(decoded.countingIn, isTrue);
        }
      },
    );

    test('decodeFrame accepts a v1 header alongside v2', () {
      final v1Bytes = PedalCodec.encodeFrame(
        goldenFrames()['idle_rec']!,
        targetVersion: PedalCodec.protocolVersionV1,
      );
      expect(v1Bytes[2], PedalCodec.protocolVersionV1);
      expect(PedalCodec.decodeFrame(v1Bytes), isNotNull);
    });

    test(
      'a v1-shaped frame decodes with looperMode multi and countingIn false '
      '(backward compat: firmware v2 receiving an app v1 frame)',
      () {
        // Built exactly as today's (pre-B5a) app would have sent it: version
        // byte 0x01, flags bits4-7 never set (they didn't exist on this
        // wire). Proves a genuinely old-app-shaped frame still decodes.
        final oldAppStyle = buildStateSysEx([
          0x00, // flags: rec mode, no clear fade/goodbye/performanceArmed
          GlobalColor.green.index,
          0,
          0,
          ...List.filled(8, 0),
          0, 0, 0, 0,
          255, // master gain (unity)
        ]);
        final decoded = PedalCodec.decodeFrame(oldAppStyle);
        expect(decoded, isNotNull);
        expect(decoded!.looperMode, PedalLooperMode.multi);
        expect(decoded.countingIn, isFalse);
      },
    );

    test(
      'downgrading a v2-intent frame to v1 loses looperMode and countingIn '
      '(the D11 degrade: app v2 talking to firmware v1)',
      () {
        final intent = goldenFrames()['mode_counting_in']!; // sync, counting in
        final v1Bytes = PedalCodec.encodeFrame(
          intent,
          targetVersion: PedalCodec.protocolVersionV1,
        );
        final decoded = PedalCodec.decodeFrame(v1Bytes);
        // The wire genuinely lost the information — decode does NOT recover
        // the original intent, only the v1-representable fields.
        expect(decoded, isNot(intent));
        expect(decoded!.looperMode, PedalLooperMode.multi);
        expect(decoded.countingIn, isFalse);
        expect(decoded.mode, intent.mode); // v1-representable fields survive
        expect(decoded.globalColor, intent.globalColor);
      },
    );

    test('rejects a reserved looperMode code (5-7) on a v2 frame', () {
      // flags byte with looperMode nibble = 5 (0b101 << 4), one past `free`
      // (index 4) — the highest currently-defined value.
      final bytes = buildStateSysEx([
        0x50, // bits4-6 = 5 (reserved)
        GlobalColor.off.index,
        0,
        0,
        ...List.filled(8, 0),
        0, 0, 0, 0,
        255,
      ], version: PedalCodec.protocolVersionV2);
      expect(PedalCodec.decodeFrame(bytes), isNull);
    });

    test(
      'a reserved looperMode code on a v1 frame is irrelevant -- v1 never '
      'reads bits 4-6 at all',
      () {
        final bytes = buildStateSysEx([
          0x50, // would be an invalid looperMode nibble at v2
          GlobalColor.off.index,
          0,
          0,
          ...List.filled(8, 0),
          0, 0, 0, 0,
          255,
        ]); // version defaults to protocolVersionV1, exercised here on purpose
        final decoded = PedalCodec.decodeFrame(bytes);
        expect(decoded, isNotNull);
        expect(decoded!.looperMode, PedalLooperMode.multi);
        expect(decoded.countingIn, isFalse);
      },
    );

    test('encodeFrame rejects an unrecognized targetVersion', () {
      expect(
        () => PedalCodec.encodeFrame(PedalStateFrame.blank(), targetVersion: 3),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('PedalCodec.firmwareNeedsUpdate (D11)', () {
    test('is true for v1 firmware', () {
      expect(
        PedalCodec.firmwareNeedsUpdate(PedalCodec.protocolVersionV1),
        isTrue,
      );
    });

    test('is false for v2 firmware', () {
      expect(
        PedalCodec.firmwareNeedsUpdate(PedalCodec.protocolVersionV2),
        isFalse,
      );
    });

    test('is false for any firmware version at least as new as v2', () {
      expect(PedalCodec.firmwareNeedsUpdate(99), isFalse);
    });
  });

  group('D11 version-pairing fixture (bit-identical baseline)', () {
    test(
      'idle_rec_v1 reproduces the exact pre-B5a wire bytes byte-for-byte',
      () {
        // Historical bytes, hand-transcribed from the pre-B5a committed
        // MANIFEST.md for `idle_rec.syx` — the "today's baseline, must stay
        // bit-identical" pairing (D11). Only the header's version byte
        // (index 2, still 0x01 here) is meaningful to this claim; everything
        // else was already covered by the generic golden round-trip.
        const historical = [
          0xF0, 0x7D, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x04, 0x00, 0x00, 0x7F, 0x7A, 0xF7,
        ];
        final bytes = PedalCodec.encodeFrame(
          explicitVersionGoldenFrames()['idle_rec_v1']!.frame,
          targetVersion: PedalCodec.protocolVersionV1,
        );
        expect(bytes, historical);
      },
    );
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
      // 0x01 and 0x02 are both recognized (D11); 0x03 is not.
      expect(
        PedalCodec.decodeFrame(buildStateSysEx(validPayload(), version: 0x03)),
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

  group('PedalCodec outbound control messages', () {
    test('encodeIdentityRequest is the Universal Identity Request', () {
      expect(PedalCodec.encodeIdentityRequest(), [
        0xF0,
        0x7E,
        0x7F,
        0x06,
        0x01,
        0xF7,
      ]);
    });

    test('encodeLoopTop is the single Start real-time byte', () {
      expect(PedalCodec.encodeLoopTop(), [PedalCodec.loopTopPulse]);
      expect(PedalCodec.loopTopPulse, 0xFA);
    });
  });
}
