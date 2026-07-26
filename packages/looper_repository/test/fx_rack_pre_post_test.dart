import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy_engine/loopy_engine.dart'
    hide
        AudioBackend,
        AudioDevice,
        BuiltInEffect,
        EngineConfig,
        LatencyState,
        LoopbackInfo,
        LoopbackKind,
        ParamReadout,
        PluginEffect,
        PluginFormat,
        PluginParamInfo,
        PluginRef,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType;
import 'package:loopy_engine/loopy_engine.dart' as le show LatencyState;

import 'helpers/fake_audio_engine.dart';

const _emptyTrackSnapshot = EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 2,
  outputChannels: 2,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: le.LatencyState.idle,
  measuredLatencyMs: -1,
  masterLengthFrames: 0,
  masterPositionFrames: 0,
  tracks: [
    TrackSnapshot(
      state: TrackState.empty,
      volume: 1,
      muted: false,
      lengthFrames: 0,
      undoDepth: 0,
      rms: 0,
      peak: 0,
      inputMask: 0x1,
      outputMask: 0x3,
      lanes: [
        LaneSnapshot(
          inputChannel: 0,
          outputMask: 0x3,
          volume: 1,
          muted: false,
          lengthFrames: 0,
          rms: 0,
          peak: 0,
        ),
      ],
    ),
  ],
);

void main() {
  group('FxRack PrePost LiveSignal', () {
    late LooperRepository repo;
    late FakeAudioEngine engine;

    setUp(() {
      engine = FakeAudioEngine()..nextSnapshot = _emptyTrackSnapshot;
      repo = LooperRepository(engine: engine)
        ..startEngine(const EngineConfig());
    });

    tearDown(() => repo.stopEngine());

    BuiltInEffect fx(TrackEffectType type) => BuiltInEffect(
      type: type,
      params: List<double>.filled(kTrackEffectParams, 0.5),
    );

    TrackEffectType typeOf(TrackEffect e) => (e as BuiltInEffect).type;

    test('setTrackPreEffects remembers Pre without touching Post', () {
      expect(
        repo.setTrackPreEffects(
          channel: 0,
          effects: [fx(TrackEffectType.delay)],
        ),
        EngineResult.ok,
      );
      expect(repo.trackPreEffects(0), hasLength(1));
      expect(repo.trackPostEffects(0), isEmpty);
      expect(repo.state.tracks[0].preEffects, hasLength(1));
      expect(engine.calls, contains('setTrackFxPre'));
    });

    test('setTrackPostEffects mirrors onto lane effects view', () {
      expect(
        repo.setTrackPostEffects(
          channel: 0,
          effects: [fx(TrackEffectType.reverb)],
        ),
        EngineResult.ok,
      );
      expect(typeOf(repo.trackPostEffects(0).single), TrackEffectType.reverb);
      expect(typeOf(repo.laneEffects(0, 0).single), TrackEffectType.reverb);
      expect(
        typeOf(repo.state.tracks[0].postEffects.single),
        TrackEffectType.reverb,
      );
    });

    test('setLaneEffects Post shim updates Track Post', () {
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [fx(TrackEffectType.drive)],
      );
      expect(typeOf(repo.trackPostEffects(0).single), TrackEffectType.drive);
    });

    test('setInputPreEffects and setInputPostEffects are independent', () {
      repo.setInputPreEffects(input: 0, effects: [fx(TrackEffectType.delay)]);
      repo.setInputPostEffects(input: 0, effects: [fx(TrackEffectType.reverb)]);
      expect(typeOf(repo.inputPreEffects(0).single), TrackEffectType.delay);
      expect(typeOf(repo.monitorEffects(0).single), TrackEffectType.reverb);
      final monitor = repo.allMonitors()[0]!;
      expect(typeOf(monitor.preEffects.single), TrackEffectType.delay);
      expect(typeOf(monitor.postEffects.single), TrackEffectType.reverb);
    });

    test('LiveSignal mode and focus are remembered', () {
      expect(
        repo.setTrackLiveSignal(channel: 0, mode: LiveSignalMode.auto),
        EngineResult.ok,
      );
      expect(repo.setLiveSignalFocus(channel: 0), EngineResult.ok);
      expect(repo.allTrackLiveSignal()[0], LiveSignalMode.auto);
      expect(repo.state.tracks[0].liveSignal, LiveSignalMode.auto);
      expect(engine.calls, contains('setTrackLiveSignal'));
      expect(engine.calls, contains('setLiveSignalFocus'));
    });

    test('snapshot PrePost: empty-track record does not copy Input Post', () {
      repo.setInputPostEffects(input: 0, effects: [fx(TrackEffectType.reverb)]);
      expect(repo.record(channel: 0), EngineResult.ok);
      expect(repo.trackPostEffects(0), isEmpty);
      expect(repo.laneEffects(0, 0), isEmpty);
    });

    test('clear keeps PrePost LiveSignal racks', () {
      repo
        ..setTrackPreEffects(
          channel: 0,
          effects: [fx(TrackEffectType.delay)],
        )
        ..setTrackPostEffects(
          channel: 0,
          effects: [fx(TrackEffectType.reverb)],
        )
        ..setTrackLiveSignal(channel: 0, mode: LiveSignalMode.on);
      expect(repo.clear(channel: 0), EngineResult.ok);
      expect(typeOf(repo.trackPreEffects(0).single), TrackEffectType.delay);
      expect(typeOf(repo.trackPostEffects(0).single), TrackEffectType.reverb);
      expect(repo.allTrackLiveSignal()[0], LiveSignalMode.on);
    });

    test('applySession restores Pre Post and LiveSignal racks', () async {
      await repo.applySession(
        SessionRig(
          trackPreEffects: {
            0: [fx(TrackEffectType.delay)],
          },
          trackPostEffects: {
            0: [fx(TrackEffectType.reverb)],
          },
          trackLiveSignal: const {0: LiveSignalMode.on},
          monitors: [
            SessionRigMonitor(
              input: 0,
              enabled: true,
              outputMask: 0x3,
              volume: 1,
              muted: false,
              preEffects: [fx(TrackEffectType.delay)],
              effects: [fx(TrackEffectType.reverb)],
            ),
          ],
        ),
      );
      expect(typeOf(repo.trackPreEffects(0).single), TrackEffectType.delay);
      expect(typeOf(repo.trackPostEffects(0).single), TrackEffectType.reverb);
      expect(repo.allTrackLiveSignal()[0], LiveSignalMode.on);
      expect(typeOf(repo.inputPreEffects(0).single), TrackEffectType.delay);
      expect(typeOf(repo.monitorEffects(0).single), TrackEffectType.reverb);
    });
  });
}
