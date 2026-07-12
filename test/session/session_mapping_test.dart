import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/session/session_mapping.dart';
import 'package:mocktail/mocktail.dart';
import 'package:session_repository/session_repository.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  group('chainsFromLooper', () {
    late LooperRepository looper;

    setUp(() {
      looper = _MockLooperRepository();
      when(looper.allLaneEffects).thenReturn(const {});
      when(looper.allMonitors).thenReturn(const {});
    });

    test('captures an enabled DRY monitor (no FX) as a SessionMonitor', () {
      // The regression: a monitor with no FX chain was dropped on save. It must
      // still be persisted so it round-trips instead of being disabled on load.
      when(looper.allMonitors).thenReturn(const {
        1: InputMonitor(input: 1, enabled: true, outputMask: 0x2),
      });

      final chains = chainsFromLooper(looper);

      expect(chains.monitors, hasLength(1));
      final monitor = chains.monitors.single;
      expect(monitor.input, 1);
      expect(monitor.enabled, isTrue);
      expect(monitor.outputMask, 0x2);
      expect(monitor.volume, 1.0);
      expect(monitor.muted, isFalse);
      // A dry monitor encodes to the empty chain.
      expect(decodeTrackEffects(monitor.encoded), isEmpty);
    });

    test('carries a monitor FX chain through the encoding', () {
      when(looper.allMonitors).thenReturn({
        0: InputMonitor(
          input: 0,
          enabled: true,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      });

      final chains = chainsFromLooper(looper);

      final decoded = decodeTrackEffects(chains.monitors.single.encoded);
      expect((decoded.single as BuiltInEffect).type, TrackEffectType.reverb);
    });

    test('emits no monitors when none are configured', () {
      expect(chainsFromLooper(looper).monitors, isEmpty);
    });
  });

  group('rigFromBundle', () {
    // Direct (always-on) coverage of `rigFromBundle`'s lane/track drop
    // branches — the env-var-gated round-trip test only covers the happy path.
    SessionLane lane(int index, String file) => SessionLane(
      lane: index,
      volume: 1,
      muted: false,
      outputMask: 0x3,
      inputChannel: index,
      layers: [SessionLayer(file: file)],
    );

    Session sessionWith(List<SessionTrack> tracks) => Session(
      sampleRate: 48000,
      channels: 1,
      baseLengthFrames: 4,
      tracks: tracks,
    );

    test('maps every lane that has decoded audio', () {
      final l0 = Float32List.fromList([1, 1, 1, 1]);
      final l1 = Float32List.fromList([2, 2, 2, 2]);
      final bundle = (
        session: sessionWith([
          SessionTrack(
            channel: 0,
            multiple: 1,
            lengthFrames: 4,
            lanes: [
              lane(0, 'track0_lane0_L0.wav'),
              lane(1, 'track0_lane1_L0.wav'),
            ],
          ),
        ]),
        laneStems: {(0, 0): l0, (0, 1): l1},
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(1));
      expect(rig.tracks.single.lanes, hasLength(2));
      expect(rig.tracks.single.lanes[0].livePcm, l0);
      expect(rig.tracks.single.lanes[1].livePcm, l1);
    });

    test('drops a lane whose PCM is missing but keeps its siblings', () {
      final l0 = Float32List.fromList([1, 1, 1, 1]);
      final bundle = (
        session: sessionWith([
          SessionTrack(
            channel: 0,
            multiple: 1,
            lengthFrames: 4,
            lanes: [
              lane(0, 'track0_lane0_L0.wav'),
              lane(1, 'track0_lane1_L0.wav'),
            ],
          ),
        ]),
        // Lane 1 has no decoded audio.
        laneStems: {(0, 0): l0},
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(1));
      expect(rig.tracks.single.lanes, hasLength(1));
      expect(rig.tracks.single.lanes.single.lane, 0);
    });

    test('drops a track whose every lane is missing its PCM', () {
      final bundle = (
        session: sessionWith([
          SessionTrack(
            channel: 0,
            multiple: 1,
            lengthFrames: 4,
            lanes: [lane(0, 'track0_lane0_L0.wav')],
          ),
          SessionTrack(
            channel: 1,
            multiple: 1,
            lengthFrames: 4,
            lanes: [lane(0, 'track1_lane0_L0.wav')],
          ),
        ]),
        // Only track 0's audio decoded.
        laneStems: {
          (0, 0): Float32List.fromList([1, 1, 1, 1]),
        },
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(1));
      expect(rig.tracks.single.channel, 0);
    });
  });
}
