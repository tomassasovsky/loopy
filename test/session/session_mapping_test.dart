import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/session/session_mapping.dart';
// The chains a performance arm records cross the boundary as ENGINE models
// (the manifest embeds them as canonical JSON), so the assertions on them name
// the engine types under an `le` prefix — everything else here is domain.
import 'package:loopy_engine/loopy_engine.dart'
    as le
    show BuiltInEffect, PluginEffect, PluginFormat, TrackEffectType;
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

  group('performanceChainsFromLooper', () {
    late LooperRepository looper;

    setUp(() {
      looper = _MockLooperRepository();
      when(looper.allLaneEffects).thenReturn(const {});
      when(looper.allMonitors).thenReturn(const {});
      when(() => looper.limiterEnabled).thenReturn(true);
      when(() => looper.limiterCeiling).thenReturn(0.99);
    });

    test('maps every lane chain to its (channel, lane) address', () {
      when(looper.allLaneEffects).thenReturn({
        (0, 1): [BuiltInEffect(type: TrackEffectType.reverb)],
        (2, 0): [BuiltInEffect(type: TrackEffectType.delay)],
      });

      final chains = performanceChainsFromLooper(looper);

      expect(
        chains.laneChains.map((c) => (c.channel, c.lane)),
        containsAll(<(int, int)>[(0, 1), (2, 0)]),
      );
    });

    test('carries built-in effect params across the engine boundary', () {
      // The manifest embeds the ENGINE models as canonical JSON, so the
      // per-effect params must survive the domain → engine conversion intact.
      when(looper.allLaneEffects).thenReturn({
        (0, 0): [
          BuiltInEffect(
            type: TrackEffectType.octaver,
            params: const [7, 0.5],
          ),
        ],
      });

      final effects = performanceChainsFromLooper(
        looper,
      ).laneChains.single.effects;

      final effect = effects.single as le.BuiltInEffect;
      expect(effect.type, le.TrackEffectType.octaver);
      expect(effect.params, [7, 0.5]);
    });

    test('carries a plugin entry ref, state and name across the boundary', () {
      when(looper.allLaneEffects).thenReturn({
        (1, 0): [
          const PluginEffect(
            ref: PluginRef(
              format: PluginFormat.vst3,
              id: 'com.example.chorus',
              version: 0x00020100,
            ),
            paramValues: {3: 0.25},
            state: 'YmFzZTY0',
            name: 'Chorus',
          ),
        ],
      });

      final effects = performanceChainsFromLooper(
        looper,
      ).laneChains.single.effects;

      final effect = effects.single as le.PluginEffect;
      expect(effect.ref.format, le.PluginFormat.vst3);
      expect(effect.ref.id, 'com.example.chorus');
      expect(effect.ref.version, 0x00020100);
      expect(effect.paramValues, {3: 0.25});
      expect(effect.state, 'YmFzZTY0');
      expect(effect.name, 'Chorus');
    });

    test('captures a monitor routing/mix and its chain', () {
      when(looper.allMonitors).thenReturn({
        1: InputMonitor(
          input: 1,
          enabled: true,
          outputMask: 0x2,
          volume: 0.75,
          muted: true,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      });

      final monitor = performanceChainsFromLooper(looper).monitors.single;

      expect(monitor.input, 1);
      expect(monitor.enabled, isTrue);
      expect(monitor.outputMask, 0x2);
      expect(monitor.volume, 0.75);
      expect(monitor.muted, isTrue);
      expect(
        (monitor.effects.single as le.BuiltInEffect).type,
        le.TrackEffectType.reverb,
      );
    });

    test('captures an enabled DRY monitor (no FX)', () {
      // Same rule as the session save: the capture documents every configured
      // monitor, not just the ones carrying an FX chain.
      when(looper.allMonitors).thenReturn(const {
        0: InputMonitor(input: 0, enabled: true),
      });

      final monitor = performanceChainsFromLooper(looper).monitors.single;

      expect(monitor.input, 0);
      expect(monitor.enabled, isTrue);
      expect(monitor.effects, isEmpty);
    });

    test('reads the real master-limiter state, even for an empty rig', () {
      final chains = performanceChainsFromLooper(looper);

      expect(chains.laneChains, isEmpty);
      expect(chains.monitors, isEmpty);
      // The bug this part fixes: an empty rig is fine, an empty LIMITER is
      // not — the engine cannot report it, so it comes from the repository.
      expect(chains.limiterEnabled, isTrue);
      expect(chains.limiterCeiling, 0.99);
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

    test('decodes chains in BOTH wire formats: legacy bare array and the '
        'FX v3 envelope (R15)', () {
      final pcm = Float32List.fromList([1, 1, 1, 1]);
      final legacy = encodeTrackEffects([
        BuiltInEffect(type: TrackEffectType.drive),
      ]);
      final envelope = encodeFxChain(
        FxChainEnvelope(
          chainEnabled: false,
          entries: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      );
      final bundle = (
        session: Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 4,
          tracks: [
            SessionTrack(
              channel: 0,
              multiple: 1,
              lengthFrames: 4,
              lanes: [lane(0, 'track0_lane0_L0.wav')],
            ),
          ],
          laneChains: [
            SessionLaneChain(channel: 0, lane: 0, encoded: legacy),
          ],
          monitors: [
            SessionMonitor(
              input: 0,
              enabled: true,
              outputMask: 0x3,
              volume: 1,
              muted: false,
              encoded: envelope,
            ),
          ],
        ),
        laneStems: {
          (0, 0): [pcm],
        },
      );

      final rig = rigFromBundle(bundle);

      final laneChain = rig.laneEffects[(0, 0)]!;
      expect((laneChain.single as BuiltInEffect).type, TrackEffectType.drive);
      final monitorChain = rig.monitors.single.effects;
      expect(
        (monitorChain.single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
    });

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
        laneStems: {
          (0, 0): [l0],
          (0, 1): [l1],
        },
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(1));
      expect(rig.tracks.single.lanes, hasLength(2));
      expect(rig.tracks.single.lanes[0].livePcm, l0);
      expect(rig.tracks.single.lanes[1].livePcm, l1);
    });

    test('maps a multi-lane track with per-lane overdub history', () {
      // Two lanes, each a 3-layer stack (undo 1, live, redo 1) — the per-lane
      // layer zip must keep each lane's ordered layers + undo/redo counts.
      SessionLane historyLane(int index, List<String> files) => SessionLane(
        lane: index,
        volume: 1,
        muted: false,
        outputMask: 0x3,
        inputChannel: index,
        undoCount: 1,
        redoCount: 1,
        layers: [for (final f in files) SessionLayer(file: f)],
      );
      final l0 = [
        Float32List.fromList([1]),
        Float32List.fromList([2]),
        Float32List.fromList([3]),
      ];
      final l1 = [
        Float32List.fromList([4]),
        Float32List.fromList([5]),
        Float32List.fromList([6]),
      ];
      final bundle = (
        session: sessionWith([
          SessionTrack(
            channel: 0,
            multiple: 1,
            lengthFrames: 1,
            lanes: [
              historyLane(0, ['t0_l0_L0.wav', 't0_l0_L1.wav', 't0_l0_L2.wav']),
              historyLane(1, ['t0_l1_L0.wav', 't0_l1_L1.wav', 't0_l1_L2.wav']),
            ],
          ),
        ]),
        laneStems: {(0, 0): l0, (0, 1): l1},
      );

      final rig = rigFromBundle(bundle);
      final lanes = rig.tracks.single.lanes;
      expect(lanes, hasLength(2));
      expect(lanes[0].layers, l0);
      expect(lanes[0].undoCount, 1);
      expect(lanes[0].redoCount, 1);
      expect(lanes[0].liveIndex, 1);
      expect(lanes[1].layers, l1);
      expect(lanes[1].undoCount, 1);
      expect(lanes[1].livePcm, l1[1]);
    });

    test('carries the track length preset (A6) through to the rig', () {
      final l0 = Float32List.fromList([1, 1, 1, 1]);
      final bundle = (
        session: sessionWith([
          SessionTrack(
            channel: 0,
            multiple: 1,
            lengthFrames: 4,
            lengthPresetBars: 4,
            lanes: [lane(0, 'track0_lane0_L0.wav')],
          ),
          SessionTrack(
            channel: 1,
            multiple: 1,
            lengthFrames: 4,
            // AUTO (0, the default) round-trips too, not just a set value.
            lanes: [lane(0, 'track1_lane0_L0.wav')],
          ),
        ]),
        laneStems: {
          (0, 0): [l0],
          (1, 0): [l0],
        },
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(2));
      expect(rig.tracks[0].lengthPresetBars, 4);
      expect(rig.tracks[1].lengthPresetBars, 0);
    });

    test(
      'carries the looper mode, primary track, and per-track one-shot '
      '(B5c) through to the rig',
      () {
        final l0 = Float32List.fromList([1, 1, 1, 1]);
        final bundle = (
          session: Session(
            sampleRate: 48000,
            channels: 1,
            baseLengthFrames: 4,
            looperMode: LooperMode.band,
            primaryTrack: 1,
            tracks: [
              SessionTrack(
                channel: 0,
                multiple: 1,
                lengthFrames: 4,
                oneShot: true,
                lanes: [lane(0, 'track0_lane0_L0.wav')],
              ),
              SessionTrack(
                channel: 1,
                multiple: 1,
                lengthFrames: 4,
                // Off (the default) round-trips too, not just a set value.
                lanes: [lane(0, 'track1_lane0_L0.wav')],
              ),
            ],
          ),
          laneStems: {
            (0, 0): [l0],
            (1, 0): [l0],
          },
        );

        final rig = rigFromBundle(bundle);
        expect(rig.looperMode, LooperMode.band);
        expect(rig.primaryTrack, 1);
        expect(rig.tracks, hasLength(2));
        expect(rig.tracks[0].oneShot, isTrue);
        expect(rig.tracks[1].oneShot, isFalse);
      },
    );

    test(
      'carries a One Shot flag pre-armed on a CONTENT-LESS channel through '
      'to the rig via the session-level set (independent review of #295): '
      'channel 2 has no SessionTrack at all (never recorded onto), so its '
      'flag only reaches the rig through Session.oneShotChannels, not '
      'through any SessionRigTrack',
      () {
        final l0 = Float32List.fromList([1, 1, 1, 1]);
        final bundle = (
          session: Session(
            sampleRate: 48000,
            channels: 1,
            baseLengthFrames: 4,
            // Channel 2 is deliberately absent from `tracks` — it holds no
            // content — yet its One Shot flag is armed at session level.
            oneShotChannels: const [0, 2],
            tracks: [
              SessionTrack(
                channel: 0,
                multiple: 1,
                lengthFrames: 4,
                oneShot: true,
                lanes: [lane(0, 'track0_lane0_L0.wav')],
              ),
            ],
          ),
          laneStems: {
            (0, 0): [l0],
          },
        );

        final rig = rigFromBundle(bundle);

        expect(rig.tracks, hasLength(1));
        expect(rig.oneShotChannels, {0, 2});
      },
    );

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
        laneStems: {
          (0, 0): [l0],
        },
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
          (0, 0): [
            Float32List.fromList([1, 1, 1, 1]),
          ],
        },
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(1));
      expect(rig.tracks.single.channel, 0);
    });
  });
}
