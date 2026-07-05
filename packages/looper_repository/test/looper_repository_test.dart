import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
// The audio-config + effect types are domain types here (from the barrel); the
// engine-typed fixtures fed to the fake engine use the `le` prefix.
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
import 'package:loopy_engine/loopy_engine.dart'
    as le
    show
        AudioDevice,
        LatencyState,
        LoopbackInfo,
        LoopbackKind,
        PluginDescriptor,
        PluginFormat,
        PluginParamInfo;

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
  latencyState: le.LatencyState.idle,
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
        latencyState: le.LatencyState.idle,
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
          latencyState: le.LatencyState.idle,
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
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );

      final track = repo.state.tracks[0];
      expect(track.lanes, hasLength(2));
      expect(track.lanes[0].inputChannel, 0);
      expect(track.lanes[0].outputMask, 0x1);
      expect(track.lanes[0].volume, closeTo(0.8, 1e-6));
      expect(track.lanes[0].effects, isEmpty);
      expect(track.lanes[1].inputChannel, 1);
      expect(track.lanes[1].muted, isTrue);
      expect(
        (track.lanes[1].effects.single as BuiltInEffect).type,
        TrackEffectType.drive,
      );
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
        latencyState: le.LatencyState.idle,
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
        latencyState: le.LatencyState.idle,
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
        latencyState: le.LatencyState.idle,
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

    test('a lane fx param change re-emits the projected state', () async {
      // Regression: setLaneEffectParam mutated the stored chain list in place,
      // but _project hands that same list to the emitted state by reference —
      // so the last-emitted state was retroactively mutated and the poll's
      // next == _last diff suppressed the update (UI never refreshed).
      const snapshot = EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
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
                volume: 1,
                muted: false,
                lengthFrames: 48000,
                rms: 0,
                peak: 0,
              ),
            ],
          ),
        ],
      );
      // Explicit params (length >= 3) so the index-2 tweak below is valid
      // regardless of any effect's default-param count.
      final repo = buildRepo()
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5, 0],
            ),
          ],
        );
      engine.nextSnapshot = snapshot;

      final emitted = <LooperState>[];
      final sub = repo.looperState.listen(emitted.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero); // initial poll
      ticker.add(null); // steady — must not re-emit
      await Future<void>.delayed(Duration.zero);
      final settled = emitted.length;

      // A live param tweak (index 2): no structural edit. It must re-emit
      // immediately — without waiting for the next poll tick — so a dragged
      // knob doesn't lag a frame behind the gesture.
      repo.setLaneEffectParam(
        channel: 0,
        lane: 0,
        index: 0,
        param: 2,
        value: 0.9,
      );
      await Future<void>.delayed(Duration.zero);

      expect(emitted.length, settled + 1, reason: 'param change must re-emit');
      expect(
        (emitted.last.tracks[0].lanes[0].effects.single as BuiltInEffect)
            .params[2],
        closeTo(0.9, 1e-9),
      );
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
            BuiltInEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5],
            ),
          ],
        );
      expect(engine.laneFx, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      // Track-addressed effects map to lane 0.
      expect(engine.laneFx[(1, 0, 0)]?.code, TrackEffectType.delay.code);
      expect(engine.laneFxParam[(1, 0, 0, 1)], 0.4);
      expect(engine.laneFxCount[(1, 0)], 1);
    });

    test('a live param tweak updates the entry without resetting it', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
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

    test(
      'a plugin entry loads through the slot ABI, not the built-in FX push',
      () {
        // A plugin slot loads through the dedicated slot ABI (setLanePlugin)
        // rather than the built-in setLaneFx push: it must not disturb the
        // built-in entries around it, and the active count still spans the
        // whole chain (so trailing built-ins keep their indices).
        buildRepo()
          ..startEngine(const EngineConfig())
          ..setTrackEffects(
            channel: 0,
            effects: [
              BuiltInEffect(type: TrackEffectType.drive),
              // index 1 is a plugin between two built-ins.
              const PluginEffect(
                ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              ),
              BuiltInEffect(type: TrackEffectType.reverb),
            ],
          );

        // Built-in entries pushed at their own indices; the plugin loads via
        // the slot ABI at index 1 (never setLaneFx).
        expect(engine.laneFx[(0, 0, 0)]?.code, TrackEffectType.drive.code);
        expect(engine.laneFx.containsKey((0, 0, 1)), isFalse);
        expect(engine.lanePlugins[(0, 0, 1)], 'p');
        expect(engine.laneFx[(0, 0, 2)]?.code, TrackEffectType.reverb.code);
        // The active count still spans all three entries.
        expect(engine.laneFxCount[(0, 0)], 3);
      },
    );

    test('a plugin entry enumerates its params into the projected chain', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.params, hasLength(1));
      expect(fx.params.single.id, 100);
      expect(fx.params.single.name, 'Mix');
    });

    test('a discrete param is enriched with its per-step labels', () {
      // A 3-state enum (stepCount 2 over [0, 2]) -> step values 0/1/2.
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Filter Type',
          unit: '',
          min: 0,
          max: 2,
          def: 0,
          stepCount: 2,
          flags: 0x01 | 0x10, // automatable + stepped
        ),
      ];
      engine.paramValueTexts.addAll({
        (100, 0.0): 'Lowpass',
        (100, 1.0): 'Highpass',
        (100, 2.0): 'Bandpass',
      });
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      final param = fx.params.single;
      expect(param.valueTexts, ['Lowpass', 'Highpass', 'Bandpass']);
      expect(param.isEnum, isTrue);
    });

    test('a discrete param with incomplete labels stays a bare knob', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Filter Type',
          unit: '',
          min: 0,
          max: 2,
          def: 0,
          stepCount: 2,
          flags: 0x01 | 0x10,
        ),
      ];
      // Only two of the three steps resolve to text -> no dropdown.
      engine.paramValueTexts.addAll({
        (100, 0.0): 'Lowpass',
        (100, 2.0): 'Bandpass',
      });
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      final param = fx.params.single;
      expect(param.valueTexts, isEmpty);
      expect(param.isEnum, isFalse);
    });

    test('lanePluginParamText forwards to the loaded slot', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Gain',
          unit: 'dB',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      engine.paramValueTexts[(100, 0.5)] = '-6.0 dB';
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      expect(
        repo.lanePluginParamText(
          channel: 0,
          lane: 0,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        '-6.0 dB',
      );
      // No plugin at that index -> null, not a throw.
      expect(
        repo.lanePluginParamText(
          channel: 0,
          lane: 0,
          index: 5,
          paramId: 100,
          value: 0.5,
        ),
        isNull,
      );
    });

    test('monitorPluginParamText forwards to the loaded monitor slot', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Gain',
          unit: 'dB',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      engine.paramValueTexts[(100, 0.5)] = '-6.0 dB';
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      expect(
        repo.monitorPluginParamText(
          input: 0,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        '-6.0 dB',
      );
      expect(
        repo.monitorPluginParamText(
          input: 9,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        isNull,
      );
    });

    test('persisted plugin paramValues replay through the RT queue', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              paramValues: {100: 0.25},
            ),
          ],
        );
      expect(engine.pluginParamSets, hasLength(1));
      expect(engine.pluginParamSets.single.paramId, 100);
      expect(engine.pluginParamSets.single.value, 0.25);
    });

    test('setLanePluginParam routes to the loaded slot and remembers it', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      expect(
        repo.setLanePluginParam(
          channel: 0,
          lane: 0,
          index: 0,
          paramId: 200,
          value: 0.8,
        ),
        EngineResult.ok,
      );
      // The set reached the plugin via the RT queue...
      expect(engine.pluginParamSets.last.paramId, 200);
      expect(engine.pluginParamSets.last.value, 0.8);
      // ...and is remembered on the entry so it survives a reload / persists.
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.paramValues[200], 0.8);
    });

    test('setLanePluginParam on a non-plugin entry is invalid', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      expect(
        repo.setLanePluginParam(
          channel: 0,
          lane: 0,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        EngineResult.invalid,
      );
    });

    test('setMonitorPluginParam on a non-plugin entry is invalid', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 1,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      expect(
        repo.setMonitorPluginParam(
          input: 1,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        EngineResult.invalid,
      );
    });

    test('setMonitorPluginParam routes to the loaded monitor slot', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 2,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'm'),
            ),
          ],
        );
      expect(engine.monitorPlugins[(2, 0)], 'm');

      expect(
        repo.setMonitorPluginParam(
          input: 2,
          index: 0,
          paramId: 300,
          value: 0.4,
        ),
        EngineResult.ok,
      );
      expect(engine.pluginParamSets.last.paramId, 300);
      expect(engine.pluginParamSets.last.value, 0.4);
      expect(
        (repo.monitorEffects(2).single as PluginEffect).paramValues[300],
        0.4,
      );
    });

    test('a plugin param set with no loaded slot is invalid', () {
      // Engine not started => no slot loaded for the remembered chain.
      final repo = buildRepo()
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..startEngine(const EngineConfig());
      // Simulate a failed load: the next plugin load returns no handle.
      engine.nextSlotHandle = null;
      repo.setTrackEffects(
        channel: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.clap, id: 'p'),
          ),
        ],
      );
      expect(
        repo.setLanePluginParam(
          channel: 0,
          lane: 0,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        EngineResult.invalid,
      );
    });

    test('openLanePluginEditor opens the loaded slot editor', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );
      expect(
        repo.openLanePluginEditor(channel: 0, lane: 0, index: 0),
        EngineResult.ok,
      );
      expect(engine.openEditors, hasLength(1));
      expect(
        repo.isLanePluginEditorOpen(channel: 0, lane: 0, index: 0),
        isTrue,
      );
    });

    test('openLanePluginEditor without a loaded plugin is invalid', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      expect(
        repo.openLanePluginEditor(channel: 0, lane: 0, index: 0),
        EngineResult.invalid,
      );
    });

    test('refreshLanePluginParams mirrors editor-driven values (D-SYNC)', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );
      // The editor moves param 100 to 0.7; the next read-back mirrors it.
      engine.nextParamValues[100] = 0.7;
      expect(
        repo.refreshLanePluginParams(channel: 0, lane: 0, index: 0),
        isTrue,
      );
      expect(
        (repo.laneEffects(0, 0).single as PluginEffect).paramValues[100],
        0.7,
      );
      // A second read-back with no change reports nothing moved.
      expect(
        repo.refreshLanePluginParams(channel: 0, lane: 0, index: 0),
        isFalse,
      );
    });

    test('closeLanePluginEditor closes the slot and reads params back', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..openLanePluginEditor(channel: 0, lane: 0, index: 0);
      engine.nextParamValues[100] = 0.9; // the editor's final state

      expect(
        repo.closeLanePluginEditor(channel: 0, lane: 0, index: 0),
        EngineResult.ok,
      );
      expect(engine.openEditors, isEmpty);
      // The close re-read landed the editor's final value in the model.
      expect(
        (repo.laneEffects(0, 0).single as PluginEffect).paramValues[100],
        0.9,
      );
    });

    test('a monitor plugin editor opens, reads back, and closes', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 200,
          name: 'Tone',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 1,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'm'),
            ),
          ],
        );
      expect(
        repo.openMonitorPluginEditor(input: 1, index: 0),
        EngineResult.ok,
      );
      expect(repo.isMonitorPluginEditorOpen(input: 1, index: 0), isTrue);

      engine.nextParamValues[200] = 0.4;
      expect(repo.refreshMonitorPluginParams(input: 1, index: 0), isTrue);
      expect(
        (repo.monitorEffects(1).single as PluginEffect).paramValues[200],
        0.4,
      );

      expect(
        repo.closeMonitorPluginEditor(input: 1, index: 0),
        EngineResult.ok,
      );
      expect(repo.isMonitorPluginEditorOpen(input: 1, index: 0), isFalse);
    });

    test('a plugin that fails to load is flagged unavailable (D-MISS)', () {
      engine.nextSlotHandle = null; // load fails (uninstalled / moved)
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'gone'),
            ),
          ],
        );
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      // Preserved as a placeholder, never dropped to `none`.
      expect(fx.unavailable, isTrue);
      expect(fx.ref.id, 'gone');
      // Not in the scan catalog -> missing, not an unsupported topology.
      expect(fx.unsupported, isFalse);
    });

    test('a restored plugin keeps its persisted name before any scan', () {
      engine.nextSlotHandle = null; // not loadable yet (catalog unscanned)
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'gone'),
              name: 'Saved Reverb',
            ),
          ],
        );
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      // The persisted name survives the bind, so the placeholder reads as the
      // plugin's name rather than a cryptic id.
      expect(fx.unavailable, isTrue);
      expect(fx.name, 'Saved Reverb');
    });

    test(
      'a restored plugin recovers itself once the '
      'cold-start scan lands',
      () async {
        // A cold restart: the chain is restored (through setTrackEffects) after
        // the engine started, so its first apply hits the still-empty scan
        // cache and the plugin loads unavailable. That unavailable entry must
        // kick a catalog scan and re-apply itself, resolving availability and
        // the descriptor name — without the user relinking by hand.
        engine
          ..pluginScanResults = const [
            le.PluginDescriptor(
              id: 'p',
              name: 'Catalog Reverb',
              vendor: 'Acme',
              path: '/Library/Audio/Plug-Ins/CLAP/reverb.clap',
              format: le.PluginFormat.clap,
              version: 0,
            ),
          ]
          // Cold start: the scan cache is empty, so the first load fails.
          ..nextSlotHandle = null;
        final repo = buildRepo()..startEngine(const EngineConfig());
        repo.setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(ref: PluginRef(format: PluginFormat.clap, id: 'p')),
          ],
        );
        // First apply against the empty cache leaves it unavailable; the
        // recovery scan is now in flight.
        expect(
          (repo.laneEffects(0, 0).single as PluginEffect).unavailable,
          isTrue,
        );

        // The plugin is loadable once scanned; joining the in-flight recovery
        // scan drives the re-apply.
        engine.nextSlotHandle = MockPluginSlotHandle('p');
        await repo.pluginCatalog.scan();

        final fx = repo.laneEffects(0, 0).single as PluginEffect;
        expect(fx.unavailable, isFalse);
        expect(fx.name, 'Catalog Reverb');
      },
    );

    test('a failed load whose id is in the catalog is flagged '
        'unsupported', () async {
      // The plugin IS installed (the scan found it) but the engine refused to
      // load it — an instrument / multi-bus topology (D-BUS), not a missing
      // file. The card must say "unsupported", not "missing".
      engine.pluginScanResults = const [
        le.PluginDescriptor(
          id: 'synth',
          name: 'Big Synth',
          vendor: 'Acme',
          path: '/Library/Audio/Plug-Ins/CLAP/synth.clap',
          format: le.PluginFormat.clap,
          version: 0,
        ),
      ];
      final repo = buildRepo()..startEngine(const EngineConfig());
      await repo.pluginCatalog.scan();

      engine.nextSlotHandle = null; // engine rejects the load (topology)
      repo.setTrackEffects(
        channel: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.clap, id: 'synth'),
          ),
        ],
      );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.unavailable, isTrue);
      expect(fx.unsupported, isTrue);
    });

    test('a loaded plugin whose installed version drifts is flagged', () async {
      // Same id, different installed version than the saved ref -> the plugin
      // still loads, but the card notes the drift (D-MISS).
      engine.pluginScanResults = const [
        le.PluginDescriptor(
          id: 'p',
          name: 'Reverb',
          vendor: 'Acme',
          path: '/Library/Audio/Plug-Ins/CLAP/reverb.clap',
          format: le.PluginFormat.clap,
          version: 0x00020000, // 2.0.0 installed
        ),
      ];
      final repo = buildRepo()..startEngine(const EngineConfig());
      await repo.pluginCatalog.scan();

      engine.nextSlotHandle = MockPluginSlotHandle('p');
      repo.setTrackEffects(
        channel: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(
              format: PluginFormat.clap,
              id: 'p',
              version: 0x00010000, // 1.0.0 saved
            ),
          ),
        ],
      );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.unavailable, isFalse);
      expect(fx.versionChanged, isTrue);
    });

    test('a loaded plugin the catalog has not seen is not flagged drifted', () {
      // No scan has run, so there is no descriptor to compare against: drift is
      // undetectable and must stay false (never a false "versions match").
      engine.nextSlotHandle = MockPluginSlotHandle('p');
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(
                format: PluginFormat.clap,
                id: 'p',
                version: 0x00010000,
              ),
            ),
          ],
        );
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.unavailable, isFalse);
      expect(fx.versionChanged, isFalse);
    });

    test('relinkLanePlugin swaps the ref, keeps state, and reloads', () {
      engine.nextSlotHandle = null; // initial load fails -> unavailable
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [
            PluginEffect(
              ref: const PluginRef(format: PluginFormat.clap, id: 'gone'),
              state: base64Encode([1, 2, 3]),
            ),
          ],
        );
      expect(
        (repo.laneEffects(0, 0).single as PluginEffect).unavailable,
        isTrue,
      );

      // A working plugin is now available; relink to it.
      engine.nextSlotHandle = MockPluginSlotHandle('new');
      expect(
        repo.relinkLanePlugin(
          channel: 0,
          lane: 0,
          index: 0,
          ref: const PluginRef(format: PluginFormat.vst3, id: 'new'),
        ),
        EngineResult.ok,
      );
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.ref.id, 'new');
      expect(fx.unavailable, isFalse);
      expect(fx.state, base64Encode([1, 2, 3])); // preserved
      // The reloaded (frozen) instance received the preserved state blob.
      expect(engine.stateSets.last, [1, 2, 3]);
    });

    test('an empty chain drops the lane and zeroes the count on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      expect(engine.laneFx[(0, 0, 0)]?.code, TrackEffectType.drive.code);

      repo.setTrackEffects(channel: 0, effects: const []);
      expect(engine.laneFxCount[(0, 0)], 0);

      engine.laneFx.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.laneFx.containsKey((0, 0, 0)), isFalse);
    });

    test('a monitor chain is deferred then re-applied on start', () {
      final repo = buildRepo()
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5],
            ),
          ],
        );
      expect(engine.monitorFx, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.monitorFx[(0, 0)]?.code, TrackEffectType.delay.code);
      expect(engine.monitorFxParam[(0, 0, 1)], 0.4);
      expect(engine.monitorFxCount[0], 1);
    });

    test('a monitor param tweak updates the entry without resetting it', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      engine.calls.clear();

      repo.setMonitorEffectParam(input: 0, index: 0, param: 0, value: 0.9);
      expect(engine.monitorFxParam[(0, 0, 0)], 0.9);
      // No setMonitorInputFx (which would reset DSP) — only the granular call.
      expect(engine.calls, isNot(contains('setMonitorInputFx')));
      expect(engine.calls, contains('setMonitorInputFxParam'));

      // The tweak is remembered and re-applied on restart.
      engine.monitorFxParam.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorFxParam[(0, 0, 0)], 0.9);
    });

    test('setMonitorOutput routes the chain and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorOutput(input: 0, mask: 0x2);
      expect(engine.monitorOutput[0], 0x2);

      engine.monitorOutput.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorOutput[0], 0x2);
    });

    test('setMonitorOutput is remembered before the engine starts', () {
      final repo = buildRepo()..setMonitorOutput(input: 1, mask: 0x1);
      expect(engine.monitorOutput, isEmpty); // not running yet
      repo.startEngine(const EngineConfig());
      expect(engine.monitorOutput[1], 0x1);
    });

    test('setMonitorVolume applies the gain and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorVolume(input: 0, volume: 0.5);
      expect(engine.monitorVolume[0], 0.5);

      engine.monitorVolume.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorVolume[0], 0.5);
    });

    test('setMonitorMute mutes the chain and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorMute(input: 0, muted: true);
      expect(engine.monitorMute[0], isTrue);

      engine.monitorMute.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorMute[0], isTrue);
    });

    test('an empty monitor chain (clean path) zeroes the count', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      expect(engine.monitorFx[(0, 0)]?.code, TrackEffectType.drive.code);

      repo.setMonitorEffects(input: 0, effects: const []);
      expect(engine.monitorFxCount[0], 0);
    });

    test('setOutputEnabled applies the gate and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setOutputEnabled(output: 1, enabled: false);
      expect(engine.outputEnabled[1], isFalse);
      expect(repo.outputEnabled(1), isFalse);
      expect(repo.outputEnabled(0), isTrue); // default-on

      // Only the off entry is remembered and re-asserted on restart.
      engine.outputEnabled.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.outputEnabled[1], isFalse);

      // Re-enabling drops the stored off entry (default-on); not re-pushed.
      repo.setOutputEnabled(output: 1, enabled: true);
      engine.outputEnabled.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.outputEnabled.containsKey(1), isFalse);
    });

    test('_project surfaces the engine output-gate mask', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        outputEnabledMask: 0x1, // only output 0 enabled
      );
      final state = buildRepo().state;
      expect(state.outputEnabledMask, 0x1);
      expect(state.isOutputEnabled(0), isTrue);
      expect(state.isOutputEnabled(1), isFalse);
    });

    test('record snapshots the input monitor chain onto the lane (G3/AC3)', () {
      // Track 0 is EMPTY (so a record is a fresh capture). Lane 0 records input
      // 0 by default.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record(); // track 0 EMPTY -> snapshot copies the input chain

      // The lane now holds a copy of the input chain.
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );

      // Editing the input chain afterwards does NOT alter the recorded lane
      // (copy-on-record, not a live reference — D3).
      repo.setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );
    });

    test('record keeps a staged lane chain when the input monitor chain is '
        'empty (dry monitor never wipes lane FX)', () {
      // Track 0 is EMPTY, so record is a fresh capture; input 0's monitor
      // chain is clean. The lane's own (staged / persistence-restored) chain
      // must survive the snapshot instead of being cleared.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..record();

      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
    });

    test('record captures the monitor plugin state onto the lane (D-P1)', () {
      engine
        ..nextState = Uint8List.fromList([1, 2, 3, 4])
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..record();

      // The lane's frozen copy carries the captured opaque state blob.
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.state, base64Encode([1, 2, 3, 4]));
    });

    test('a monitor plugin whose capture fails is dropped (bypassed) on the '
        'lane (D-P1)', () {
      engine
        ..nextState =
            Uint8List(0) // capture failure -> bypass
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..record();

      expect(repo.laneEffects(0, 0), isEmpty);
    });

    test('a mid-chain capture failure drops only that entry, keeping order '
        '(D-P1)', () {
      engine
        ..nextState =
            Uint8List(0) // every plugin capture fails -> bypass
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.drive),
            const PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
            BuiltInEffect(type: TrackEffectType.reverb),
          ],
        )
        ..record();

      // The plugin (index 1) is dropped; the surrounding built-ins keep order.
      final lane = repo.laneEffects(0, 0);
      expect(lane, hasLength(2));
      expect((lane[0] as BuiltInEffect).type, TrackEffectType.drive);
      expect((lane[1] as BuiltInEffect).type, TrackEffectType.reverb);
    });

    test('a corrupt state blob is ignored; the plugin still loads', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      // A garbage (non-base64) blob must not crash the restore.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              state: 'not-valid-base64!!!',
            ),
          ],
        );
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.unavailable, isFalse); // loaded fine, just at default state
      expect(fx.params, hasLength(1));
    });

    test('restoring a lane plugin replays its state blob (D-P1 frozen)', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [
            PluginEffect(
              ref: const PluginRef(format: PluginFormat.clap, id: 'p'),
              state: base64Encode([9, 8, 7]),
            ),
          ],
        );
      // The lane loaded its own instance and pushed the saved blob to it.
      expect(engine.stateSets, isNotEmpty);
      expect(engine.stateSets.last, [9, 8, 7]);
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

    test('per-input monitors are independent and survive a restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorInputEnabled(input: 0, enabled: true)
        ..setMonitorOutput(input: 0, mask: 0x1)
        ..setMonitorInputEnabled(input: 1, enabled: true)
        ..setMonitorOutput(input: 1, mask: 0x2);
      expect(engine.monitorInputEnabled[0], isTrue);
      expect(engine.monitorOutput[0], 0x1);
      expect(engine.monitorOutput[1], 0x2);

      // Disabling one input leaves the other untouched.
      repo.setMonitorInputEnabled(input: 0, enabled: false);
      expect(engine.monitorInputEnabled[0], isFalse);
      expect(engine.monitorInputEnabled[1], isTrue);

      // Both are re-applied on restart.
      engine.monitorInputEnabled.clear();
      engine.monitorOutput.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorInputEnabled[0], isFalse);
      expect(engine.monitorInputEnabled[1], isTrue);
      expect(engine.monitorOutput[0], 0x1);
      expect(engine.monitorOutput[1], 0x2);
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
      engine.loopback = const le.LoopbackInfo(
        available: true,
        kind: le.LoopbackKind.monitor,
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
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
        );

    const pinned = le.AudioDevice(
      id: 'out-1',
      name: 'Scarlett 2i2',
      isDefault: false,
      isInput: false,
    );
    const captureDevice = le.AudioDevice(
      id: 'in-1',
      name: 'Built-in Mic',
      isDefault: false,
      isInput: true,
    );
    const otherDevice = le.AudioDevice(
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

    test('devices() forwards to the engine enumeration, mapped to domain', () {
      engine.devices = const [pinned];
      final repo = buildSupervised();
      // The repository maps engine AudioDevice -> domain AudioDevice.
      expect(repo.devices(), const [
        AudioDevice(
          id: 'out-1',
          name: 'Scarlett 2i2',
          isDefault: false,
          isInput: false,
        ),
      ]);
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

  group('pluginCatalog', () {
    test('exposes a lazily-built, stable catalog over the engine', () {
      final repo = buildRepo();
      final catalog = repo.pluginCatalog;
      expect(catalog, isA<PluginCatalog>());
      // Lazy + cached: the same instance every read.
      expect(repo.pluginCatalog, same(catalog));
    });
  });

  group('engine factories', () {
    test('createMockEngine builds a mock + its deterministic start config', () {
      final mock = createMockEngine();

      // The start config mirrors the mock's defaults (and value-equality
      // exercises the domain EngineConfig props).
      expect(
        mock.startConfig,
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          inputChannels: 18,
          outputChannels: 20,
          playbackDeviceId: 'mock-interface',
          captureDeviceId: 'mock-interface',
        ),
      );
      // The engine drives a repository that comes up on the mock config.
      final repo = LooperRepository(
        engine: mock.engine,
        ticker: const Stream<void>.empty(),
      );
      addTearDown(repo.dispose);
      expect(repo.startEngine(mock.startConfig).isOk, isTrue);
    });
  });
}
