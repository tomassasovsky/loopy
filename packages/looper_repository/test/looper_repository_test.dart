import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy_engine/loopy_engine.dart';

import 'helpers/fake_audio_engine.dart';

const _playingSnapshot = EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 2,
  outputChannels: 4,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: LatencyState.idle,
  measuredLatencyMs: -1,
  masterLengthFrames: 96000,
  masterPositionFrames: 24000,
  tracks: [
    TrackSnapshot(
      state: TrackState.playing,
      volume: 0.8,
      muted: false,
      lengthFrames: 96000,
      undoDepth: 1,
      rms: 0.3,
      peak: 0.5,
      inputMask: 0x2,
      outputMask: 0x2,
    ),
  ],
);

void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;

  setUp(() {
    engine = FakeAudioEngine();
    ticker = StreamController<void>.broadcast();
  });

  tearDown(() => ticker.close());

  LooperRepository buildRepo() =>
      LooperRepository(engine: engine, ticker: ticker.stream);

  group('poll interval', () {
    test('reports and updates the configured cadence', () {
      final repo = LooperRepository(
        engine: engine,
        ticker: ticker.stream,
        pollInterval: const Duration(milliseconds: 32),
      );
      addTearDown(repo.dispose);

      expect(repo.pollInterval, const Duration(milliseconds: 32));

      repo.setPollInterval(const Duration(milliseconds: 8));
      expect(repo.pollInterval, const Duration(milliseconds: 8));

      // Setting the same value is a no-op.
      repo.setPollInterval(const Duration(milliseconds: 8));
      expect(repo.pollInterval, const Duration(milliseconds: 8));
    });

    test('default-timer polling keeps running after a cadence change', () {
      // No injected ticker: the real Timer path is exercised.
      final repo = LooperRepository(
        engine: engine,
        pollInterval: const Duration(milliseconds: 32),
      );
      addTearDown(repo.dispose);

      // Subscribing starts the default poll timer.
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);

      repo.setPollInterval(const Duration(milliseconds: 8));
      expect(repo.pollInterval, const Duration(milliseconds: 8));
    });
  });

  group('projection', () {
    test('maps a snapshot into looper domain models', () {
      engine.nextSnapshot = _playingSnapshot;
      final repo = buildRepo();

      final state = repo.state;
      expect(state.transport.isRunning, isTrue);
      expect(state.transport.masterLengthFrames, 96000);
      expect(state.transport.masterPositionFrames, 24000);
      expect(state.transport.progress, closeTo(0.25, 1e-6));
      expect(state.track.state, TrackState.playing);
      expect(state.track.volume, closeTo(0.8, 1e-6));
      expect(state.track.muted, isFalse);
      expect(state.track.lengthFrames, 96000);
      expect(state.track.playheadFrames, 24000);
      expect(state.track.canUndo, isTrue);
      expect(state.track.hasContent, isTrue);
      expect(state.track.inputMask, 0x2);
      expect(state.track.outputMask, 0x2);
      expect(state.status.deviceName, 'Fake Device');
      expect(state.status.sampleRate, 48000);
      expect(state.status.inputChannels, 2);
      expect(state.status.outputChannels, 4);
      expect(state.status.isConnected, isTrue);
    });

    test('projects multiple tracks with their channel indices', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: LatencyState.idle,
        measuredLatencyMs: -1,
        masterLengthFrames: 48000,
        tracks: [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 48000,
            undoDepth: 0,
            rms: 0,
            peak: 0,
          ),
          TrackSnapshot(
            state: TrackState.overdubbing,
            volume: 0.5,
            muted: true,
            lengthFrames: 48000,
            undoDepth: 1,
            rms: 0,
            peak: 0,
          ),
        ],
      );
      final state = buildRepo().state;
      expect(state.tracks, hasLength(2));
      expect(state.tracks[0].channel, 0);
      expect(state.tracks[1].channel, 1);
      expect(state.tracks[1].state, TrackState.overdubbing);
      expect(state.tracks[1].muted, isTrue);
      expect(state.hasContent, isTrue);
    });

    test('maps a per-lane snapshot into Track.lanes', () {
      engine
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: LatencyState.idle,
          measuredLatencyMs: -1,
          masterLengthFrames: 48000,
          tracks: [
            TrackSnapshot(
              state: TrackState.playing,
              volume: 1,
              muted: false,
              lengthFrames: 48000,
              undoDepth: 0,
              rms: 0,
              peak: 0,
              lanes: [
                LaneSnapshot(
                  inputChannel: 0,
                  outputMask: 0x1,
                  volume: 0.8,
                  muted: false,
                  lengthFrames: 48000,
                  rms: 0.2,
                  peak: 0.4,
                ),
                LaneSnapshot(
                  inputChannel: 1,
                  outputMask: 0x2,
                  volume: 0.5,
                  muted: true,
                  lengthFrames: 48000,
                  rms: 0,
                  peak: 0,
                ),
              ],
            ),
          ],
        )
        // Remembered lane-1 effects are attached to the projected lane.
        ..startResult = EngineResult.ok;
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          channel: 0,
          lane: 1,
          effects: [TrackEffect(type: TrackEffectType.drive)],
        );

      final track = repo.state.tracks[0];
      expect(track.lanes, hasLength(2));
      expect(track.lanes[0].inputChannel, 0);
      expect(track.lanes[0].outputMask, 0x1);
      expect(track.lanes[0].volume, closeTo(0.8, 1e-6));
      expect(track.lanes[0].effects, isEmpty);
      expect(track.lanes[1].inputChannel, 1);
      expect(track.lanes[1].muted, isTrue);
      expect(track.lanes[1].effects.single.type, TrackEffectType.drive);
    });

    test('projects a track loop multiple', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: LatencyState.idle,
        measuredLatencyMs: -1,
        masterLengthFrames: 48000,
        tracks: [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 96000,
            undoDepth: 0,
            rms: 0,
            peak: 0,
            multiple: 2,
          ),
        ],
      );
      final track = buildRepo().state.tracks.first;
      expect(track.multiple, 2);
      expect(track.isMultiple, isTrue);
      expect(track.lengthFrames, 96000);
    });

    test('initial snapshot projects an empty looper', () {
      final repo = buildRepo();
      final state = repo.state;
      expect(state.track.state, TrackState.empty);
      expect(state.track.hasContent, isFalse);
      expect(state.transport.hasLoop, isFalse);
      expect(state.transport.progress, 0);
    });

    test('projects the excluded input mask onto EngineStatus', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        inputChannels: 2,
        outputChannels: 2,
        excludedInputMask: 0x2,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: LatencyState.idle,
        measuredLatencyMs: -1,
      );
      expect(buildRepo().state.status.excludedInputMask, 0x2);
    });

    test('projects fx added latency onto EngineStatus (frames + ms)', () {
      engine.nextSnapshot = const EngineSnapshot(
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
        latencyState: LatencyState.idle,
        measuredLatencyMs: -1,
        fxAddedLatencyFrames: 1024,
      );
      final status = buildRepo().state.status;
      expect(status.fxAddedLatencyFrames, 1024);
      expect(status.fxAddedLatencyMs, closeTo(1024 * 1000 / 48000, 1e-9));
    });
  });

  group('looperState stream', () {
    test('emits a projected state on each tick, distinctly', () async {
      final repo = buildRepo();
      final emitted = <LooperState>[];
      final sub = repo.looperState.listen(emitted.add);
      addTearDown(sub.cancel);

      // onListen polls once (initial/empty).
      await Future<void>.delayed(Duration.zero);

      engine.nextSnapshot = _playingSnapshot;
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // A tick with no change does not emit again.
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(2));
      expect(emitted.first.track.state, TrackState.empty);
      expect(emitted.last.track.state, TrackState.playing);
    });

    test('a late subscriber immediately receives the current state', () async {
      final repo = buildRepo();

      // A first listener drives the engine to a steady playing state.
      engine.nextSnapshot = _playingSnapshot;
      final first = repo.looperState.listen((_) {});
      addTearDown(first.cancel);
      await Future<void>.delayed(Duration.zero);

      // A second listener that subscribes afterwards must get the current
      // state right away, without waiting for the next change.
      LooperState? lateState;
      final second = repo.looperState.listen((s) => lateState = s);
      addTearDown(second.cancel);
      await Future<void>.delayed(Duration.zero);

      expect(lateState, isNotNull);
      expect(lateState!.track.state, TrackState.playing);
    });

    test('polling restarts cleanly across subscribe/cancel cycles', () async {
      // The default ticker is single-subscription; a subscribe → cancel →
      // subscribe cycle (hot restart, a bloc rebuild) must not throw
      // "Stream has already been listened to".
      final repo = LooperRepository(engine: engine);
      addTearDown(repo.dispose);

      final sub1 = repo.looperState.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub1.cancel();

      final sub2 = repo.looperState.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub2.cancel();
    });
  });

  group('commands forward to the engine', () {
    test('each command calls the matching engine method', () {
      buildRepo()
        ..startEngine(const EngineConfig(sampleRate: 48000))
        ..record()
        ..stopTrack()
        ..play()
        ..undo()
        ..redo()
        ..clear()
        ..measureLatency()
        ..stopEngine()
        ..setVolume(0.5)
        ..setMute(muted: true);

      expect(
        engine.calls,
        containsAllInOrder(<String>[
          'start',
          'record',
          'stopTrack',
          'play',
          'undo',
          'redo',
          'clear',
          'measureLatency',
          'stop',
        ]),
      );
      expect(engine.lastConfig?.sampleRate, 48000);
      expect(engine.lastVolume, 0.5);
      expect(engine.lastMuted, isTrue);
    });

    test('startEngine stores the last successful config', () {
      const config = EngineConfig(
        sampleRate: 96000,
        bufferFrames: 64,
      );
      final repo = buildRepo();

      expect(repo.lastEngineConfig, isNull);
      expect(repo.startEngine(config), EngineResult.ok);
      expect(repo.lastEngineConfig, config);
    });

    test('startEngine does not store config when start fails', () {
      engine.startResult = EngineResult.device;
      const config = EngineConfig(sampleRate: 96000);
      final repo = buildRepo();

      expect(repo.startEngine(config), EngineResult.device);
      expect(repo.lastEngineConfig, isNull);
    });

    test('setQuantize is deferred until running, then applied', () {
      // Not running yet: the value is remembered but not pushed to the engine.
      final repo = buildRepo()..setQuantize(enabled: true);
      expect(engine.lastQuantize, isNull);

      // A start re-applies the remembered quantize state.
      repo.startEngine(const EngineConfig());
      expect(engine.lastQuantize, isTrue);
    });

    test('setQuantize applies immediately while running', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      // The start re-applied the default (off).
      expect(engine.lastQuantize, isFalse);

      repo.setQuantize(enabled: true);
      expect(engine.lastQuantize, isTrue);
    });

    test('per-track quantize overrides are deferred then re-applied', () {
      final repo = buildRepo()
        ..setTrackQuantize(channel: 1, enabled: true)
        ..setTrackQuantize(channel: 2, enabled: false);
      expect(engine.trackQuantize, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.trackQuantize[1], isTrue);
      expect(engine.trackQuantize[2], isFalse);
    });

    test(
      'clearing a per-track override (null) inherits the global default',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setTrackQuantize(channel: 1, enabled: true);
        expect(engine.trackQuantize[1], isTrue);

        repo.setTrackQuantize(channel: 1, enabled: null);
        expect(engine.trackQuantize[1], isNull);

        // A later restart does not re-apply the cleared override.
        engine.trackQuantize.clear();
        repo.startEngine(const EngineConfig());
        expect(engine.trackQuantize.containsKey(1), isFalse);
      },
    );

    test('rec/dub, auto-record and multiples re-apply on start', () {
      final repo = buildRepo()
        ..setRecDub(enabled: true)
        ..setAutoRecord(enabled: true)
        ..setDefaultMultiple(multiple: 2)
        ..setTrackMultiple(channel: 1, multiple: 3);
      expect(engine.lastRecDub, isNull); // not running yet
      expect(engine.trackMultiple, isEmpty);

      repo.startEngine(const EngineConfig());
      expect(engine.lastRecDub, isTrue);
      expect(engine.lastAutoRecord, isTrue);
      expect(engine.lastDefaultMultiple, 2);
      expect(engine.trackMultiple[1], 3);
    });

    test('setMasterGain is deferred until running, then re-applied', () {
      // Not running yet: the value is remembered but not pushed to the engine,
      // and the call still reports success.
      final repo = buildRepo();
      expect(repo.setMasterGain(0.5), EngineResult.ok);
      expect(engine.lastMasterGain, isNull);

      // A start re-applies the remembered gain so it survives device changes.
      repo.startEngine(const EngineConfig());
      expect(engine.lastMasterGain, 0.5);
    });

    test('setMasterGain re-applies on every restart (device change)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMasterGain(0.4);
      expect(engine.lastMasterGain, 0.4);

      // A restart (e.g. a reconnect or device switch) resets the engine, so the
      // remembered gain must be pushed again — this is why it is stored.
      engine.lastMasterGain = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastMasterGain, 0.4);
    });

    test('setMasterGain applies immediately while running', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      // The start re-applied the default (unity).
      expect(engine.lastMasterGain, 1.0);

      repo.setMasterGain(0.25);
      expect(engine.lastMasterGain, 0.25);
    });

    test('setMasterGain clamps to 0..1 before reaching the engine', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMasterGain(2);
      expect(engine.lastMasterGain, 1.0);
      repo.setMasterGain(-1);
      expect(engine.lastMasterGain, 0.0);
    });

    test('a per-lane effects chain is deferred then re-applied on start', () {
      final repo = buildRepo()
        ..setTrackEffects(
          channel: 1,
          effects: [
            TrackEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5],
            ),
          ],
        );
      expect(engine.laneFx, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      // Track-addressed effects map to lane 0.
      expect(engine.laneFx[(1, 0, 0)], TrackEffectType.delay);
      expect(engine.laneFxParam[(1, 0, 0, 1)], 0.4);
      expect(engine.laneFxCount[(1, 0)], 1);
    });

    test('a live param tweak updates the entry without resetting it', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [TrackEffect(type: TrackEffectType.drive)],
        );
      engine.calls.clear();

      repo.setTrackEffectParam(channel: 0, index: 0, param: 0, value: 0.9);
      expect(engine.laneFxParam[(0, 0, 0, 0)], 0.9);
      // No setLaneFx (which would reset DSP) — only the granular param call.
      expect(engine.calls, isNot(contains('setLaneFx')));
      expect(engine.calls, contains('setLaneFxParam'));

      // The tweak is remembered and re-applied on restart.
      engine.laneFxParam.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.laneFxParam[(0, 0, 0, 0)], 0.9);
    });

    test('an empty chain drops the lane and zeroes the count on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [TrackEffect(type: TrackEffectType.drive)],
        );
      expect(engine.laneFx[(0, 0, 0)], TrackEffectType.drive);

      repo.setTrackEffects(channel: 0, effects: const []);
      expect(engine.laneFxCount[(0, 0)], 0);

      engine.laneFx.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.laneFx.containsKey((0, 0, 0)), isFalse);
    });

    test('a monitor lane chain is deferred then re-applied on start', () {
      final repo = buildRepo()
        ..setMonitorLaneEffects(
          input: 0,
          lane: 0,
          effects: [
            TrackEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5],
            ),
          ],
        );
      expect(engine.monitorLaneFx, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.monitorLaneFx[(0, 0, 0)], TrackEffectType.delay);
      expect(engine.monitorLaneFxParam[(0, 0, 0, 1)], 0.4);
      expect(engine.monitorLaneFxCount[(0, 0)], 1);
    });

    test(
      'a monitor lane param tweak updates the entry without resetting it',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setMonitorLaneEffects(
            input: 0,
            lane: 0,
            effects: [TrackEffect(type: TrackEffectType.drive)],
          );
        engine.calls.clear();

        repo.setMonitorLaneEffectParam(
          input: 0,
          lane: 0,
          index: 0,
          param: 0,
          value: 0.9,
        );
        expect(engine.monitorLaneFxParam[(0, 0, 0, 0)], 0.9);
        // No setMonitorLaneFx (which would reset DSP) — only the granular call.
        expect(engine.calls, isNot(contains('setMonitorLaneFx')));
        expect(engine.calls, contains('setMonitorLaneFxParam'));

        // The tweak is remembered and re-applied on restart.
        engine.monitorLaneFxParam.clear();
        repo.startEngine(const EngineConfig());
        expect(engine.monitorLaneFxParam[(0, 0, 0, 0)], 0.9);
      },
    );

    test('setMonitorLaneOutput routes a lane and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorLaneOutput(input: 0, lane: 1, mask: 0x2);
      expect(engine.monitorLaneOutput[(0, 1)], 0x2);

      // Remembered and re-applied on the next start.
      engine.monitorLaneOutput.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorLaneOutput[(0, 1)], 0x2);
    });

    test('setMonitorLaneOutput is remembered before the engine starts', () {
      final repo = buildRepo()
        ..setMonitorLaneOutput(input: 1, lane: 0, mask: 0x1);
      expect(engine.monitorLaneOutput, isEmpty); // not running yet
      repo.startEngine(const EngineConfig());
      expect(engine.monitorLaneOutput[(1, 0)], 0x1);
    });

    test('setMonitorLaneVolume applies the gain and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorLaneVolume(input: 0, lane: 0, volume: 0.5);
      expect(engine.monitorLaneVolume[(0, 0)], 0.5);

      // Remembered and re-applied on the next start.
      engine.monitorLaneVolume.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorLaneVolume[(0, 0)], 0.5);
    });

    test('setMonitorLaneMute mutes a lane and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorLaneMute(input: 0, lane: 1, muted: true);
      expect(engine.monitorLaneMute[(0, 1)], isTrue);

      engine.monitorLaneMute.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorLaneMute[(0, 1)], isTrue);
    });

    test('an empty monitor lane chain (clean path) zeroes the count', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorLaneEffects(
          input: 0,
          lane: 0,
          effects: [TrackEffect(type: TrackEffectType.drive)],
        );
      expect(engine.monitorLaneFx[(0, 0, 0)], TrackEffectType.drive);

      // A no-FX lane is the clean (dry) path: the chain length drops to 0.
      repo.setMonitorLaneEffects(input: 0, lane: 0, effects: const []);
      expect(engine.monitorLaneFxCount[(0, 0)], 0);
    });

    test('clearing a track multiple (0) drops the override', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackMultiple(channel: 1, multiple: 2);
      expect(engine.trackMultiple[1], 2);

      repo.setTrackMultiple(channel: 1, multiple: 0);
      expect(engine.trackMultiple[1], 0);

      engine.trackMultiple.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.trackMultiple.containsKey(1), isFalse);
    });

    test(
      'a per-input monitor enable is deferred until running, then applied',
      () {
        final repo = buildRepo()
          ..setMonitorInputEnabled(input: 1, enabled: true);
        expect(engine.monitorInputEnabled, isEmpty); // not running yet

        repo.startEngine(const EngineConfig());
        expect(engine.monitorInputEnabled[1], isTrue);
      },
    );

    test('setMonitorLaneCount remembers, defers, and re-applies on start', () {
      final repo = buildRepo()..setMonitorLaneCount(input: 2, count: 3);
      // Not running yet: remembered but not pushed to the engine.
      expect(engine.monitorLaneCount, isEmpty);

      // Remembering is proven by re-applying the count on the next start.
      repo.startEngine(const EngineConfig());
      expect(engine.monitorLaneCount[2], 3);

      // Count 1 (the default) drops the override and does not re-apply.
      repo.setMonitorLaneCount(input: 2, count: 1);
      engine.monitorLaneCount.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorLaneCount.containsKey(2), isFalse);
    });

    test('per-input monitors are independent and survive a restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorInputEnabled(input: 0, enabled: true)
        ..setMonitorLaneOutput(input: 0, lane: 0, mask: 0x1)
        ..setMonitorInputEnabled(input: 1, enabled: true)
        ..setMonitorLaneOutput(input: 1, lane: 0, mask: 0x2);
      expect(engine.monitorInputEnabled[0], isTrue);
      expect(engine.monitorLaneOutput[(0, 0)], 0x1);
      expect(engine.monitorLaneOutput[(1, 0)], 0x2);

      // Disabling one input leaves the other untouched.
      repo.setMonitorInputEnabled(input: 0, enabled: false);
      expect(engine.monitorInputEnabled[0], isFalse);
      expect(engine.monitorInputEnabled[1], isTrue);

      // Both are re-applied on restart.
      engine.monitorInputEnabled.clear();
      engine.monitorLaneOutput.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorInputEnabled[0], isFalse);
      expect(engine.monitorInputEnabled[1], isTrue);
      expect(engine.monitorLaneOutput[(0, 0)], 0x1);
      expect(engine.monitorLaneOutput[(1, 0)], 0x2);
    });

    test('engineVersion is forwarded', () {
      final repo = buildRepo();
      expect(repo.engineVersion, 'fake-engine');
    });

    test('setRecordOffset forwards to the engine', () {
      buildRepo().setRecordOffset(480);
      expect(engine.calls, contains('setRecordOffset'));
      expect(engine.lastRecordOffset, 480);
    });

    test('setInputMask maps the lowest selected input onto lane 0', () {
      // 0x6 selects inputs 1 and 2; the lowest (1) records into lane 0.
      buildRepo().setInputMask(channel: 2, mask: 0x6);
      expect(engine.calls, contains('setLaneInput'));
      expect(engine.laneInput[(2, 0)], 1);
    });

    test('setOutputMask forwards the mask onto lane 0', () {
      buildRepo().setOutputMask(channel: 1, mask: 0x5);
      expect(engine.calls, contains('setLaneOutput'));
      expect(engine.laneOutput[(1, 0)], 0x5);
    });

    test('setLaneCount remembers, defers, and re-applies on start', () {
      final repo = buildRepo()..setLaneCount(channel: 2, count: 3);
      // Not running yet: remembered but not pushed to the engine.
      expect(engine.laneCount, isEmpty);
      expect(repo.laneCount(2), 3);

      repo.startEngine(const EngineConfig());
      expect(engine.laneCount[2], 3);

      // Count 1 (the default) drops the override and does not re-apply.
      repo.setLaneCount(channel: 2, count: 1);
      expect(repo.laneCount(2), 1);
      engine.laneCount.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.laneCount.containsKey(2), isFalse);
    });

    test('detectLoopback forwards the engine result', () {
      engine.loopback = const LoopbackInfo(
        available: true,
        kind: LoopbackKind.monitor,
        deviceName: 'Monitor of Built-in',
      );
      final repo = buildRepo();
      final info = repo.detectLoopback();
      expect(info.available, isTrue);
      expect(info.kind, LoopbackKind.monitor);
      expect(engine.calls, contains('detectLoopback'));
    });
  });

  group('reconnect supervisor', () {
    late StreamController<void> reconnectTicker;

    setUp(() => reconnectTicker = StreamController<void>.broadcast());
    tearDown(() => reconnectTicker.close());

    LooperRepository buildSupervised() => LooperRepository(
      engine: engine,
      ticker: ticker.stream,
      reconnectTicker: reconnectTicker.stream,
    );

    EngineSnapshot runningSnapshot({required bool devicePresent}) =>
        EngineSnapshot(
          isRunning: true,
          devicePresent: devicePresent,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: LatencyState.idle,
          measuredLatencyMs: -1,
        );

    const pinned = AudioDevice(
      id: 'out-1',
      name: 'Scarlett 2i2',
      isDefault: false,
      isInput: false,
    );
    const captureDevice = AudioDevice(
      id: 'in-1',
      name: 'Built-in Mic',
      isDefault: false,
      isInput: true,
    );
    const otherDevice = AudioDevice(
      id: 'out-2',
      name: 'Headphones',
      isDefault: false,
      isInput: false,
    );

    int startCount() => engine.calls.where((c) => c == 'start').length;
    int stopCount() => engine.calls.where((c) => c == 'stop').length;

    test('reopens a pinned device when it reappears', () async {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      final repo = buildSupervised()
        ..startEngine(const EngineConfig(playbackDeviceId: 'out-1'));
      expect(startCount(), 1);

      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      // Device is lost: snapshot reports present == false.
      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // Still absent from enumeration → no restart yet.
      engine.devices = const [];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(startCount(), 1);

      // Reappears → stop + restart on the same device.
      engine.devices = const [pinned];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(engine.calls, containsAllInOrder(<String>['stop', 'start']));
      expect(startCount(), 2);
      expect(engine.lastConfig?.playbackDeviceId, 'out-1');
    });

    test('never restarts the system default on transient loss', () async {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      final repo = buildSupervised()
        ..startEngine(const EngineConfig()); // empty device id = default
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // Even though the device "reappears", a default config is never pinned.
      engine.devices = const [pinned];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(startCount(), 1);
      expect(engine.calls, isNot(contains('stop')));
    });

    test('a deliberate stop cancels reconnection', () async {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      final repo = buildSupervised()
        ..startEngine(const EngineConfig(playbackDeviceId: 'out-1'));
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      repo.stopEngine();
      final startsAfterStop = startCount();

      // The device reappears, but the user stopped — no auto-restart.
      engine.devices = const [pinned];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(startCount(), startsAfterStop);
    });

    test('devicePresent is projected onto EngineStatus', () {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      expect(buildSupervised().state.status.devicePresent, isTrue);
      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      expect(buildSupervised().state.status.devicePresent, isFalse);
    });

    test('reopens a pinned capture device when it reappears', () async {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      final repo = buildSupervised()
        ..startEngine(const EngineConfig(captureDeviceId: 'in-1'));
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // A playback device alone does not satisfy a pinned capture device.
      engine.devices = const [pinned];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(startCount(), 1);

      // The capture device returns → reopen.
      engine.devices = const [pinned, captureDevice];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(startCount(), 2);
      expect(engine.lastConfig?.captureDeviceId, 'in-1');
    });

    test(
      'does not retry a failed restart until the device list changes',
      () async {
        engine.nextSnapshot = runningSnapshot(devicePresent: true);
        final repo = buildSupervised()
          ..startEngine(const EngineConfig(playbackDeviceId: 'out-1'));
        final sub = repo.looperState.listen((_) {});
        addTearDown(sub.cancel);
        await Future<void>.delayed(Duration.zero);

        engine.nextSnapshot = runningSnapshot(devicePresent: false);
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);

        // Device present, but the engine refuses to open it.
        engine
          ..devices = const [pinned]
          ..startResult = EngineResult.device;
        reconnectTicker.add(null);
        await Future<void>.delayed(Duration.zero);
        final stopsAfterFirst = stopCount();
        final startsAfterFirst = startCount();
        expect(startsAfterFirst, 2); // one failed reopen attempt

        // Same device list → no further thrash.
        reconnectTicker.add(null);
        await Future<void>.delayed(Duration.zero);
        expect(stopCount(), stopsAfterFirst);
        expect(startCount(), startsAfterFirst);

        // The list changes (a re-plug) → retry, and this time it succeeds.
        engine
          ..startResult = EngineResult.ok
          ..devices = const [pinned, otherDevice];
        reconnectTicker.add(null);
        await Future<void>.delayed(Duration.zero);
        expect(startCount(), startsAfterFirst + 1);
      },
    );

    test('devices() forwards to the engine enumeration', () {
      engine.devices = const [pinned];
      final repo = buildSupervised();
      expect(repo.devices(), const [pinned]);
      expect(engine.calls, contains('enumerateDevices'));
    });
  });

  group('dispose', () {
    test('disposes the engine and closes the stream', () async {
      final repo = buildRepo();
      await repo.dispose();
      expect(engine.calls, contains('dispose'));
    });
  });
}
