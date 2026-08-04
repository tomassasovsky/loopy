import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/session/session_mapping.dart';
// The chains a performance arm records cross the boundary as ENGINE models
// (the manifest embeds them as canonical JSON), so the assertions on them name
// the engine types under an `le` prefix — everything else here is domain.
import 'package:segno_engine/segno_engine.dart'
    as le
    show BuiltInEffect, PluginEffect, PluginFormat, TrackEffectType;
import 'package:session_repository/session_repository.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  group('chainsFromLooper', () {
    late LooperRepository looper;

    setUp(() {
      looper = _MockLooperRepository();
      when(looper.allLaneChains).thenReturn(const {});
      when(looper.allTrackChains).thenReturn(const {});
      when(looper.masterChainEnvelope).thenReturn(const FxChainEnvelope());
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
      // A dry monitor encodes to the empty (enabled) envelope.
      expect(decodeFxChain(monitor.encoded), const FxChainEnvelope());
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

      final decoded = decodeFxChain(chains.monitors.single.encoded).entries;
      expect((decoded.single as BuiltInEffect).type, TrackEffectType.reverb);
    });

    test('emits no monitors when none are configured', () {
      expect(chainsFromLooper(looper).monitors, isEmpty);
    });

    test('encodes every stage as the chain ENVELOPE — chain flag, per-slot '
        'enabled bits and inheritance meta all inside the string (R15)', () {
      when(looper.allLaneChains).thenReturn({
        (0, 0): FxChainEnvelope(
          chainEnabled: false,
          meta: const FxChainMeta(inheritedFrom: [1, 2]),
          entries: [
            BuiltInEffect(
              type: TrackEffectType.drive,
              enabled: false,
              slotId: 'aa-1',
            ),
          ],
        ),
      });
      when(looper.allMonitors).thenReturn(const {
        0: InputMonitor(input: 0, enabled: true, chainEnabled: false),
      });

      final chains = chainsFromLooper(looper);

      final lane = decodeFxChain(chains.laneChains.single.encoded);
      expect(lane.chainEnabled, isFalse);
      expect(lane.meta?.inheritedFrom, [1, 2]);
      final laneFx = lane.entries.single as BuiltInEffect;
      expect(laneFx.enabled, isFalse);
      expect(laneFx.slotId, 'aa-1');
      // A dry monitor whose chain flag is off still persists that flag — the
      // one place it can live is the envelope (no per-flag settings key).
      expect(decodeFxChain(chains.monitors.single.encoded).chainEnabled, false);
    });

    test('captures the two BUS stages (Track + Master) as envelopes', () {
      when(looper.allTrackChains).thenReturn({
        1: FxChainEnvelope(
          chainEnabled: false,
          entries: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      });
      when(looper.masterChainEnvelope).thenReturn(
        FxChainEnvelope(
          entries: [BuiltInEffect(type: TrackEffectType.filter)],
        ),
      );

      final chains = chainsFromLooper(looper);

      expect(chains.trackChains.single.channel, 1);
      final track = decodeFxChain(chains.trackChains.single.encoded);
      expect(track.chainEnabled, isFalse);
      expect(
        (track.entries.single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
      final master = decodeFxChain(chains.masterChain);
      expect(master.chainEnabled, isTrue);
      expect(
        (master.entries.single as BuiltInEffect).type,
        TrackEffectType.filter,
      );
    });

    test("emits the manifest's empty-string Master spelling for a rig with no "
        'Master state — one way to say "empty", and it still overwrites a '
        'leftover on load', () {
      final chains = chainsFromLooper(looper);

      expect(chains.trackChains, isEmpty);
      expect(chains.masterChain, '');
      expect(decodeFxChain(chains.masterChain), const FxChainEnvelope());
    });
  });

  group('performanceChainsFromLooper', () {
    late LooperRepository looper;

    setUp(() {
      looper = _MockLooperRepository();
      when(looper.allLaneChains).thenReturn(const {});
      when(looper.allTrackChains).thenReturn(const {});
      when(looper.masterChainEnvelope).thenReturn(const FxChainEnvelope());
      when(looper.allMonitors).thenReturn(const {});
      when(() => looper.limiterEnabled).thenReturn(true);
      when(() => looper.limiterCeiling).thenReturn(0.99);
    });

    test('maps every lane chain to its (channel, lane) address', () {
      when(looper.allLaneChains).thenReturn({
        (0, 1): FxChainEnvelope(
          entries: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
        (2, 0): FxChainEnvelope(
          entries: [BuiltInEffect(type: TrackEffectType.delay)],
        ),
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
      when(looper.allLaneChains).thenReturn({
        (0, 0): FxChainEnvelope(
          entries: [
            BuiltInEffect(
              type: TrackEffectType.octaver,
              params: const [7, 0.5],
            ),
          ],
        ),
      });

      final effects = performanceChainsFromLooper(
        looper,
      ).laneChains.single.effects;

      final effect = effects.single as le.BuiltInEffect;
      expect(effect.type, le.TrackEffectType.octaver);
      expect(effect.params, [7, 0.5]);
    });

    test('carries a plugin entry ref, state and name across the boundary', () {
      when(looper.allLaneChains).thenReturn({
        (1, 0): const FxChainEnvelope(
          entries: [
            PluginEffect(
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
        ),
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

    test('records the BUS stages and every chain-enabled flag (R20/R3)', () {
      when(looper.allLaneChains).thenReturn({
        (0, 0): FxChainEnvelope(
          chainEnabled: false,
          entries: [BuiltInEffect(type: TrackEffectType.drive)],
        ),
      });
      when(looper.allTrackChains).thenReturn({
        1: FxChainEnvelope(
          chainEnabled: false,
          entries: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      });
      when(looper.masterChainEnvelope).thenReturn(
        FxChainEnvelope(
          chainEnabled: false,
          entries: [
            BuiltInEffect(type: TrackEffectType.filter, enabled: false),
          ],
        ),
      );
      when(looper.allMonitors).thenReturn(const {
        0: InputMonitor(input: 0, enabled: true, chainEnabled: false),
      });

      final chains = performanceChainsFromLooper(looper);

      // A bypassed chain must replay bypassed, so every flag is recorded —
      // the manifest is the only place a replay can learn them from.
      expect(chains.laneChains.single.chainEnabled, isFalse);
      expect(chains.monitors.single.chainEnabled, isFalse);
      expect(chains.trackChains.single.channel, 1);
      expect(chains.trackChains.single.chainEnabled, isFalse);
      expect(
        (chains.trackChains.single.effects.single as le.BuiltInEffect).type,
        le.TrackEffectType.reverb,
      );
      expect(chains.masterChainEnabled, isFalse);
      final master = chains.masterEffects.single as le.BuiltInEffect;
      expect(master.type, le.TrackEffectType.filter);
      expect(master.enabled, isFalse);
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

      final laneChain = rig.laneChains[(0, 0)]!.entries;
      expect((laneChain.single as BuiltInEffect).type, TrackEffectType.drive);
      final monitorChain = rig.monitors.single.effects;
      expect(
        (monitorChain.single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
    });

    test('decodes the v5 BUS stages into the rig, chain flags included', () {
      final pcm = Float32List.fromList([1, 1, 1, 1]);
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
          trackChains: [
            SessionTrackChain(
              channel: 0,
              encoded: encodeFxChain(
                FxChainEnvelope(
                  chainEnabled: false,
                  entries: [BuiltInEffect(type: TrackEffectType.reverb)],
                ),
              ),
            ),
          ],
          masterChain: encodeFxChain(
            FxChainEnvelope(
              entries: [BuiltInEffect(type: TrackEffectType.filter)],
            ),
          ),
        ),
        laneStems: {
          (0, 0): [pcm],
        },
      );

      final rig = rigFromBundle(bundle);

      final track = rig.trackChains[0]!;
      expect(track.chainEnabled, isFalse);
      expect(
        (track.entries.single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
      expect(rig.masterChain.chainEnabled, isTrue);
      expect(
        (rig.masterChain.entries.single as BuiltInEffect).type,
        TrackEffectType.filter,
      );
    });

    test('a v4 bundle (no bus-stage fields at all) yields empty bus stages, '
        'every level enabled — the presence-keyed migration [R15]', () {
      final pcm = Float32List.fromList([1, 1, 1, 1]);
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
          // A v4 manifest's Loop chain: the bare entries array, no envelope.
          laneChains: [
            SessionLaneChain(
              channel: 0,
              lane: 0,
              encoded: encodeTrackEffects([
                BuiltInEffect(type: TrackEffectType.drive),
              ]),
            ),
          ],
        ),
        laneStems: {
          (0, 0): [pcm],
        },
      );

      final rig = rigFromBundle(bundle);

      expect(rig.trackChains, isEmpty);
      expect(rig.masterChain, const FxChainEnvelope());
      // The lane it DID describe loads enabled at both levels, with no
      // inheritance marker — and no slot ids yet (the repository mints those).
      final loop = rig.laneChains[(0, 0)]!;
      expect(loop.chainEnabled, isTrue);
      expect(loop.meta, isNull);
      final loopFx = loop.entries.single as BuiltInEffect;
      expect(loopFx.enabled, isTrue);
      expect(loopFx.slotId, isNull);
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
