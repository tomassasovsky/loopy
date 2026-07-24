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
          // undo asks what the tap would do before making it, so it knows
          // whether to put a cleared take's FX chains back.
          'undoRestoresClear',
          'undo',
          'redo',
          // The user's clear leaves a way back; only session load erases
          // outright (via the engine's plain `clear`).
          'clearUndoable',
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

    test('setRecordOffset is deferred until running, then re-applied', () {
      final repo = buildRepo();
      expect(repo.setRecordOffset(240), EngineResult.ok);
      expect(engine.lastRecordOffset, isNull); // not pushed while stopped

      repo.startEngine(const EngineConfig());
      expect(engine.lastRecordOffset, 240); // re-applied on start
    });

    test('setRecordOffset re-applies on every restart (device change)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setRecordOffset(240);
      expect(engine.lastRecordOffset, 240);

      // A restart (reconnect / device switch) resets the engine's offset to 0,
      // so the remembered compensation must be pushed again.
      engine.lastRecordOffset = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastRecordOffset, 240);
    });

    test('setRecordOffset clamps a negative to zero', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setRecordOffset(-5);
      expect(engine.lastRecordOffset, 0);
    });

    test('an engine-measured offset is captured from the poll and re-applied '
        'on restart', () async {
      final repo = buildRepo()..startEngine(const EngineConfig());
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);

      // A measurement auto-sets the engine's offset (not via setRecordOffset);
      // the poll must mirror it into the remembered value.
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
        recordOffsetFrames: 240,
      );
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // A restart re-applies the CAPTURED offset, not a stale zero.
      engine.lastRecordOffset = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastRecordOffset, 240);
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

    test(
      'a plugin that fails to load is flagged unavailable (D-MISS)',
      () async {
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
        // Cold-start recovery kicks a scan; let it complete (it finds nothing)]
        // so the entry settles from the transient loading state to the genuine
        // unavailable placeholder.
        await repo.pluginCatalog.scan();
        final fx = repo.laneEffects(0, 0).single as PluginEffect;
        // Preserved as a placeholder, never dropped to `none`.
        expect(fx.unavailable, isTrue);
        expect(fx.ref.id, 'gone');
        // Not in the scan catalog -> missing, not an unsupported topology.
        expect(fx.unsupported, isFalse);
      },
    );

    test(
      'a failed plugin keeps its persisted name in the placeholder',
      () async {
        engine.nextSlotHandle = null; // not loadable (catalog has no match)
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
        await repo.pluginCatalog.scan(); // settle recovery -> unavailable
        final fx = repo.laneEffects(0, 0).single as PluginEffect;
        // The persisted name survives the bind + recovery, so the placeholder
        // reads as the plugin's name rather than a cryptic id.
        expect(fx.unavailable, isTrue);
        expect(fx.name, 'Saved Reverb');
      },
    );

    test(
      'a restored plugin recovers itself once the cold-start scan lands',
      () async {
        // A cold restart: the chain is restored (through setTrackEffects) after
        // the engine started, so its first apply hits the still-empty scan
        // cache and the plugin fails to load. The recovery flips it to
        // "loading…" (F5) and kicks a catalog scan; when that lands the entry
        // re-applies itself, resolving availability + the descriptor name —
        // without the user relinking by hand.
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
        // First apply against the empty cache fails; recovery flips it to
        // loading (not a premature "unavailable") and its scan is now in
        // flight.
        final mid = repo.laneEffects(0, 0).single as PluginEffect;
        expect(mid.loading, isTrue);
        expect(mid.unavailable, isFalse);

        // The plugin is loadable once scanned; joining the in-flight recovery
        // scan drives the re-apply.
        engine.nextSlotHandle = MockPluginSlotHandle('p');
        await repo.pluginCatalog.scan();

        final fx = repo.laneEffects(0, 0).single as PluginEffect;
        expect(fx.loading, isFalse);
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

    test('a restored plugin reads as loading while the boot scan is pending, '
        'then unavailable once it lands still missing (F5)', () async {
      // Cold boot: the plugin can't load (empty native cache) and a scan will
      // run. While the scan is pending the entry must render "loading", not a
      // premature "unavailable" — then flip to unavailable if it stays missing.
      engine
        ..nextSlotHandle =
            null // load fails (cold cache)
        ..scanProgressOverride = const PluginScanProgress(
          done: false, // the boot scan does not complete yet
          found: 0,
          scanned: 0,
          total: 1,
        );
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
      addTearDown(repo.dispose);

      // The startup scan is kicked and pending -> loading, not unavailable.
      var fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.loading, isTrue);
      expect(fx.unavailable, isFalse);

      // Let the scan complete with the plugin still absent -> unavailable.
      engine.scanProgressOverride = const PluginScanProgress(
        done: true,
        found: 0,
        scanned: 1,
        total: 1,
      );
      await repo.pluginCatalog.scan(); // joins + drains the in-flight scan

      fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.loading, isFalse);
      expect(fx.unavailable, isTrue);
    });

    test('a restored MONITOR plugin also reads as loading during the boot '
        'scan (F5, monitor apply path)', () async {
      // The cold-start recovery flips unavailable entries to loading on both
      // the lane and monitor apply paths — cover the monitor call site too so a
      // monitor-only regression is caught.
      engine
        ..nextSlotHandle = null
        ..scanProgressOverride = const PluginScanProgress(
          done: false,
          found: 0,
          scanned: 0,
          total: 1,
        );
      final repo = buildRepo()
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      final fx = repo.monitorEffects(0).single as PluginEffect;
      expect(fx.loading, isTrue);
      expect(fx.unavailable, isFalse);
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

    test('relinkLanePlugin swaps the ref, keeps state, and reloads', () async {
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
      await repo.pluginCatalog.scan(); // settle recovery -> unavailable
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

    test('the record snapshot fires onLaneChainChanged for each copied lane '
        '(F3)', () {
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
      final changed = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..onLaneChainChanged = (channel, lane) {
          changed.add((channel, lane));
        }
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);

      // The notification fired for the take's lane, and the reported chain is
      // the post-take (snapshot-copied) one.
      expect(changed, [(0, 0)]);
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );
    });

    test('a dry monitor does not fire onLaneChainChanged (nothing copied)', () {
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
      final changed = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..onLaneChainChanged = (channel, lane) {
          changed.add((channel, lane));
        }
        ..record(); // clean input chain -> no snapshot copy
      addTearDown(repo.dispose);

      expect(changed, isEmpty);
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

    test('clear drops the take FX chain so a dry re-record does not inherit it '
        '(leftover-from-previous-config fix)', () {
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
      final persisted = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..onLaneChainChanged = (channel, lane) {
          persisted.add((channel, lane));
        }
        // Config A: monitor [reverb, delay], record onto the lane.
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.reverb),
            BuiltInEffect(type: TrackEffectType.delay),
          ],
        )
        ..record();
      addTearDown(repo.dispose);
      expect(repo.laneEffects(0, 0), hasLength(2));

      // Erase the take and go dry (a config change), then re-record.
      repo
        ..clear()
        ..setMonitorEffects(input: 0, effects: const [])
        ..record();

      // The fresh dry take is dry — A's chain did not survive the clear — and
      // the emptied chain was persisted (so a restart can't replay it).
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(persisted, contains((0, 0)));
    });

    test('the user clear takes the undoable engine path', () {
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
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      engine.calls.clear();

      repo.clear();

      expect(engine.calls, contains('clearUndoable'));
      expect(engine.calls, isNot(contains('clear')));
    });

    test('undoing a clear puts the take FX chain back and re-persists it', () {
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
      final persisted = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..onLaneChainChanged = (channel, lane) {
          persisted.add((channel, lane));
        }
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.reverb),
            BuiltInEffect(type: TrackEffectType.delay),
          ],
        )
        ..record();
      addTearDown(repo.dispose);
      expect(repo.laneEffects(0, 0), hasLength(2));

      repo.clear();
      expect(repo.laneEffects(0, 0), isEmpty);

      // The engine says this undo restores the cleared take, so the chain the
      // clear erased comes back with it.
      engine.undoRestoresClearResult = true;
      persisted.clear();
      repo.undo();

      expect(repo.laneEffects(0, 0), hasLength(2));
      expect(
        repo.laneEffects(0, 0).map((e) => (e as BuiltInEffect).type),
        [TrackEffectType.reverb, TrackEffectType.delay],
      );
      // Re-persisted, or a restart would replay the clear's emptied chain over
      // the restored take (F3).
      expect(persisted, contains((0, 0)));
    });

    test('an undo that peels a layer leaves the FX chain alone', () {
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
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..record();
      addTearDown(repo.dispose);

      repo.clear();
      // The engine reports no restore point (a fresh recording retired it),
      // so the stale snapshot must stay inert rather than resurrect a chain
      // onto a take that no longer exists.
      engine.undoRestoresClearResult = false;
      repo.undo();

      expect(repo.laneEffects(0, 0), isEmpty);
    });

    test(
      'applySession clears destructively — a loaded session is not undoable',
      () {
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
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);
        engine.calls.clear();

        unawaited(repo.applySession(const SessionRig()));

        expect(engine.calls, contains('clear'));
        expect(engine.calls, isNot(contains('clearUndoable')));
      },
    );

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

    test('record PUSHES the snapshotted chain to the engine, not just the '
        'cache (one-authority sink)', () {
      // The repository is the sole record-time snapshot authority: after a
      // record-from-EMPTY it must push the copied lane chain to the engine (the
      // engine no longer self-snapshots), so the engine holds exactly what the
      // repo cached.
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
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.delay),
            BuiltInEffect(type: TrackEffectType.reverb),
          ],
        )
        ..record();

      // The engine's lane FX now mirror the snapshot the repo computed. (The
      // fake records the engine-package enum, hidden here; compare by name.)
      expect(engine.laneFx[(0, 0, 0)]?.name, 'delay');
      expect(engine.laneFx[(0, 0, 1)]?.name, 'reverb');
      expect(engine.laneFxCount[(0, 0)], 2);
      // The lane-FX push is enqueued BEFORE the record command, so the chain is
      // published before the take can ever play back (no audible gap).
      expect(
        engine.calls.lastIndexOf('setLaneFxCount') <
            engine.calls.indexOf('record'),
        isTrue,
      );
    });

    test('record pushes the captured plugin WITH its frozen state to the '
        'engine (not a placeholder — D-P1)', () {
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
      buildRepo()
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

      // The lane plugin was loaded on the engine and seeded with the exact
      // opaque state captured from the monitor slot — the frozen instance, not
      // a stateless placeholder (the C-side clobber the fix removes).
      expect(engine.lanePlugins[(0, 0, 0)], 'p');
      expect(engine.stateSets, isNotEmpty);
      expect(engine.stateSets.last, Uint8List.fromList([1, 2, 3, 4]));
    });

    test('a dry monitor pushes NO lane FX edit on record (non-clobber)', () {
      // Track 0 EMPTY, input 0 monitor clean, lane 0 holds a staged chain. The
      // record must not touch the engine's lane FX (never a count=0 push), so a
      // deliberately staged / restored engine chain survives untouched.
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
        );
      engine.calls.clear();
      repo.record();

      // No lane-FX command rode the ring for this dry take.
      expect(engine.calls.where((c) => c.startsWith('setLaneFx')), isEmpty);
    });

    test('an overdub (non-EMPTY track) neither snapshots nor pushes lane '
        'FX', () {
      // Track 0 is PLAYING — a record press is an overdub, not a fresh capture,
      // so the monitor chain must NOT be snapshot-copied or pushed (the gate
      // the fix preserves).
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
        tracks: [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 96000,
            undoDepth: 1,
            rms: 0,
            peak: 0,
          ),
        ],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        );
      engine.calls.clear();
      repo.record();

      expect(engine.calls.where((c) => c.startsWith('setLaneFx')), isEmpty);
      expect(repo.laneEffects(0, 0), isEmpty);
    });

    test('a non-empty monitor whose every plugin capture fails overwrites a '
        'staged lane to empty on cache AND engine (D2 + one-authority)', () {
      // The all-captures-fail edge: input 0 monitors a single plugin whose
      // state capture fails (bypassed), while lane 0 holds a staged chain. The
      // monitored chain still overwrites the lane (D2) — reducing it to empty —
      // and, crucially, that empty is PUSHED so a stale staged engine chain
      // can't outlive the take (cache == engine). This is NOT the dry-monitor
      // path (which keeps the lane); the monitor here is non-empty.
      engine
        ..nextState =
            Uint8List(0) // capture failure -> the entry is dropped
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
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );
      engine.calls.clear();
      repo.record();

      // Cache is emptied AND the engine was pushed the empty chain (count 0) —
      // the staged reverb no longer sounds anywhere.
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(engine.laneFxCount[(0, 0)], 0);
    });

    test('a later take captures the CURRENT monitor chain, leaving an earlier '
        "take's snapshot intact (D3)", () {
      // Two temporally-separate takes on two empty tracks: track 0 records
      // input 0 monitoring [delay]; the monitor is then retuned to [drive] and
      // track 1 (lane 0 records input 1) records. Each take froze the chain
      // that was live at ITS record — neither take mutates the other.
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
        tracks: [TrackSnapshot.empty(), TrackSnapshot.empty()],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneInput(channel: 1, lane: 0, inputChannel: 1)
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record() // track 0 freezes [delay]
        ..setMonitorEffects(
          input: 1,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..record(channel: 1); // track 1 freezes [drive]

      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );
      expect(
        (repo.laneEffects(1, 0).single as BuiltInEffect).type,
        TrackEffectType.drive,
      );
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

    test('setRecordOffset forwards to the engine while running', () {
      // Now a cached setter (deferred until running, re-applied on restart), so
      // it forwards while the engine is up — the deferred/restart paths are
      // covered in the audio-config group.
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setRecordOffset(480);
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

    test('setMute on a multi-lane track mutes EVERY lane, not just lane 0', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneCount(channel: 2, count: 3);
      addTearDown(repo.dispose);

      repo.setMute(muted: true, channel: 2);
      expect(engine.laneMute[(2, 0)], isTrue);
      expect(engine.laneMute[(2, 1)], isTrue);
      expect(engine.laneMute[(2, 2)], isTrue);

      // Unmute spans the whole track too.
      repo.setMute(muted: false, channel: 2);
      expect(engine.laneMute[(2, 0)], isFalse);
      expect(engine.laneMute[(2, 1)], isFalse);
      expect(engine.laneMute[(2, 2)], isFalse);
    });

    test(
      'setVolume on a multi-lane track sets EVERY lane, not just lane 0',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setLaneCount(channel: 2, count: 3);
        addTearDown(repo.dispose);

        repo.setVolume(0.4, channel: 2);
        expect(engine.laneVol[(2, 0)], 0.4);
        expect(engine.laneVol[(2, 1)], 0.4);
        expect(engine.laneVol[(2, 2)], 0.4);
      },
    );

    test('clearing a muted multi-lane track unmutes every lane (so a later '
        'record/overdub is audible)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneCount(channel: 1, count: 2)
        ..setMute(muted: true, channel: 1);
      addTearDown(repo.dispose);
      expect(engine.laneMute[(1, 0)], isTrue);
      expect(engine.laneMute[(1, 1)], isTrue);

      // The clear path (engine clear + track-level unmute, as the bloc/cubit do).
      repo
        ..clear(channel: 1)
        ..setMute(muted: false, channel: 1);

      // Regression: lane 1 must not stay muted (only lane 0 got it before).
      expect(engine.laneMute[(1, 0)], isFalse);
      expect(engine.laneMute[(1, 1)], isFalse);
    });

    test('recording onto a PLAYING track (overdub) unmutes every lane, like a '
        'fresh take does', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneCount(channel: 0, count: 2)
        ..setMute(muted: true);
      addTearDown(repo.dispose);
      expect(engine.laneMute[(0, 0)], isTrue);
      expect(engine.laneMute[(0, 1)], isTrue);

      // Track 0 is playing -> this record() starts an overdub.
      engine.nextSnapshot = _playingSnapshot;
      repo.record();

      expect(engine.laneMute[(0, 0)], isFalse);
      expect(engine.laneMute[(0, 1)], isFalse);
      expect(engine.calls, contains('record'));
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

  group('tempo grid + click + count-in (A4b)', () {
    test('setTempo is deferred until running, then re-applied', () {
      final repo = buildRepo()..setTempo(140);
      expect(engine.lastTempoBpm, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastTempoBpm, 140);
    });

    test('setTempo applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setTempo(90);
      expect(engine.lastTempoBpm, 90);
    });

    test(
      'an unset tempo is never pushed on start (0 would clamp up to 30)',
      () {
        buildRepo().startEngine(const EngineConfig());
        expect(engine.lastTempoBpm, isNull);
      },
    );

    test('setTempo re-applies on every restart (device change)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTempo(128);
      expect(engine.lastTempoBpm, 128);

      // A restart (reconnect / device switch) resets the engine's tempo grid
      // to the tempo-free defaults, so the remembered tempo must be pushed
      // again.
      engine.lastTempoBpm = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastTempoBpm, 128);
    });

    test('setTimeSignature is deferred until running, then re-applied', () {
      final repo = buildRepo()..setTimeSignature(3, 4);
      expect(engine.lastTimeSignature, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastTimeSignature, (3, 4));
    });

    test('setTimeSignature applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setTimeSignature(5, 8);
      expect(engine.lastTimeSignature, (5, 8));
    });

    test('tapTempo forwards to the engine and is never remembered', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..tapTempo();
      expect(engine.calls, contains('tapTempo'));

      // A momentary action, not remembered state: a restart never replays it.
      engine.calls.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.calls, isNot(contains('tapTempo')));
    });

    test('setSyncTempo is deferred until running, then re-applied', () {
      final repo = buildRepo()..setSyncTempo(on: false);
      expect(engine.lastSyncTempo, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastSyncTempo, isFalse);
    });

    test('setQuantizeDiv is deferred until running, then re-applied', () {
      final repo = buildRepo()..setQuantizeDiv(GridDivision.eighth);
      expect(engine.lastQuantizeDiv, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastQuantizeDiv, GridDivision.eighth);
    });

    test('setClickMode is deferred until running, then re-applied', () {
      final repo = buildRepo()..setClickMode(ClickMode.playRec);
      expect(engine.lastClickMode, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastClickMode, ClickMode.playRec);
    });

    test('setClickOutput is deferred until running, then re-applied', () {
      final repo = buildRepo()..setClickOutput(0x3);
      expect(engine.lastClickOutput, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastClickOutput, 0x3);
    });

    test('setClickVolume is deferred until running, then re-applied', () {
      final repo = buildRepo()..setClickVolume(0.5);
      expect(engine.lastClickVolume, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastClickVolume, 0.5);
    });

    test('setClickVolume applies immediately while running', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      // The start re-applied the default (unity).
      expect(engine.lastClickVolume, 1.0);

      repo.setClickVolume(0.25);
      expect(engine.lastClickVolume, 0.25);
    });

    test('setCountIn is deferred until running, then re-applied', () {
      final repo = buildRepo()..setCountIn(2);
      expect(engine.lastCountIn, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastCountIn, 2);
    });

    test('setCountIn clamps a negative to zero', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setCountIn(-3);
      expect(engine.lastCountIn, 0);
    });

    test('setLooperMode is deferred until running, then re-applied', () {
      final repo = buildRepo()..setLooperMode(LooperMode.sync);
      expect(engine.lastLooperMode, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastLooperMode, LooperMode.sync);
    });

    test('setLooperMode applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setLooperMode(LooperMode.band);
      expect(engine.lastLooperMode, LooperMode.band);
    });

    test(
      'the grid-off defaults (signature 4/4, sync on, quantize div/click/ '
      'count-in off, looper mode multi) still re-apply on a plain start',
      () {
        buildRepo().startEngine(const EngineConfig());
        expect(engine.lastTimeSignature, (4, 4));
        expect(engine.lastSyncTempo, isTrue);
        expect(engine.lastQuantizeDiv, GridDivision.off);
        expect(engine.lastClickMode, ClickMode.off);
        expect(engine.lastClickOutput, 0);
        expect(engine.lastClickVolume, 1.0);
        expect(engine.lastCountIn, 0);
        expect(engine.lastLooperMode, LooperMode.multi);
      },
    );

    test(
      'signature, sync, quantize div, click mode/output/volume, count-in, '
      'and looper mode re-apply on every restart (device change)',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setTimeSignature(3, 4)
          ..setSyncTempo(on: false)
          ..setQuantizeDiv(GridDivision.bar)
          ..setClickMode(ClickMode.rec)
          ..setClickOutput(0x1)
          ..setClickVolume(0.7)
          ..setCountIn(4)
          ..setLooperMode(LooperMode.free);

        engine
          ..lastTimeSignature = null
          ..lastSyncTempo = null
          ..lastQuantizeDiv = null
          ..lastClickMode = null
          ..lastClickOutput = null
          ..lastClickVolume = null
          ..lastCountIn = null
          ..lastLooperMode = null;
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());

        expect(engine.lastTimeSignature, (3, 4));
        expect(engine.lastSyncTempo, isFalse);
        expect(engine.lastQuantizeDiv, GridDivision.bar);
        expect(engine.lastClickMode, ClickMode.rec);
        expect(engine.lastClickOutput, 0x1);
        expect(engine.lastClickVolume, 0.7);
        expect(engine.lastCountIn, 4);
        expect(engine.lastLooperMode, LooperMode.free);
      },
    );

    test(
      'setTrackLengthPreset is deferred until running, then re-applied',
      () {
        final repo = buildRepo()..setTrackLengthPreset(channel: 1, bars: 4);
        expect(engine.trackLengthPreset, isEmpty); // not running yet

        repo.startEngine(const EngineConfig());
        expect(engine.trackLengthPreset[1], 4);
      },
    );

    test('setTrackLengthPreset applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackLengthPreset(channel: 2, bars: 8);
      expect(engine.trackLengthPreset[2], 8);
    });

    test('setTrackLengthPreset(0) clears a remembered preset (AUTO)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackLengthPreset(channel: 1, bars: 4);
      expect(engine.trackLengthPreset[1], 4);

      repo.setTrackLengthPreset(channel: 1, bars: 0);
      expect(engine.trackLengthPreset[1], 0);

      // A restart no longer replays the cleared preset.
      engine.trackLengthPreset.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.trackLengthPreset, isEmpty);
    });

    test(
      'per-track length presets re-apply on every restart (device change)',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setTrackLengthPreset(channel: 1, bars: 3);
        expect(engine.trackLengthPreset[1], 3);

        engine.trackLengthPreset.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackLengthPreset[1], 3);
      },
    );

    test('crownPrimary is deferred until running, then re-applied', () {
      final repo = buildRepo()..crownPrimary(channel: 2);
      expect(engine.lastCrownedChannel, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastCrownedChannel, 2);
    });

    test('crownPrimary applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..crownPrimary(channel: 5);
      expect(engine.lastCrownedChannel, 5);
    });

    test(
      'the crown re-applies on every restart (device change), like looper '
      'mode — D18, no un-crown call means the cache never has a "default" '
      'to fall back to, only a remembered channel',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..crownPrimary(channel: 4);
        expect(engine.lastCrownedChannel, 4);

        engine.lastCrownedChannel = null;
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.lastCrownedChannel, 4);
      },
    );

    test('a never-crowned track does not push crownPrimary on start', () {
      buildRepo().startEngine(const EngineConfig());
      expect(engine.lastCrownedChannel, isNull);
    });

    test('setOneShot is deferred until running, then re-applied', () {
      final repo = buildRepo()..setOneShot(channel: 1, oneShot: true);
      expect(engine.trackOneShot, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.trackOneShot[1], isTrue);
    });

    test('setOneShot applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setOneShot(channel: 2, oneShot: true);
      expect(engine.trackOneShot[2], isTrue);
    });

    test('setOneShot(false) clears a remembered flag', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setOneShot(channel: 1, oneShot: true);
      expect(engine.trackOneShot[1], isTrue);

      repo.setOneShot(channel: 1, oneShot: false);
      expect(engine.trackOneShot[1], isFalse);

      // A restart no longer replays the cleared flag.
      engine.trackOneShot.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.trackOneShot, isEmpty);
    });

    test(
      'per-track one-shot flags re-apply on every restart (device change)',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setOneShot(channel: 3, oneShot: true);
        expect(engine.trackOneShot[3], isTrue);

        engine.trackOneShot.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackOneShot[3], isTrue);
      },
    );

    test(
      'TransportState projects every tempo-grid + click + count-in + '
      'looper-mode field from the snapshot',
      () {
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
          tempoBpm: 128,
          tempoSource: TempoSource.manual,
          tsNum: 3,
          syncTempo: false,
          quantizeDiv: GridDivision.quarter,
          loopBars: 4,
          currentBeat: 2,
          clickMode: ClickMode.playRec,
          clickMask: 0x3,
          clickVolume: 0.8,
          countInBars: 2,
          countingIn: true,
          countInBeatsLeft: 3,
          looperMode: LooperMode.band,
          primaryTrack: 2,
        );

        // primaryTrack now projects from the repository's own re-apply
        // cache, not the raw snapshot field (independent review of #295,
        // D18 stale-crown fix — see `_project`'s doc) — crown through the
        // real API so the cache agrees with the snapshot fixture above,
        // matching how a genuinely-crowned engine is reached in practice.
        final transport =
            (buildRepo()..crownPrimary(channel: 2)).state.transport;
        expect(transport.tempoBpm, 128);
        expect(transport.tempoSource, TempoSource.manual);
        expect(transport.tsNum, 3);
        expect(transport.tsDen, 4);
        expect(transport.syncTempo, isFalse);
        expect(transport.quantizeDiv, GridDivision.quarter);
        expect(transport.loopBars, 4);
        expect(transport.currentBeat, 2);
        expect(transport.clickMode, ClickMode.playRec);
        expect(transport.clickMask, 0x3);
        expect(transport.clickVolume, closeTo(0.8, 1e-9));
        expect(transport.countInBars, 2);
        expect(transport.countingIn, isTrue);
        expect(transport.countInBeatsLeft, 3);
        expect(transport.looperMode, LooperMode.band);
        expect(transport.primaryTrack, 2);
      },
    );

    test(
      'TransportState defaults to the tempo-free grid-off values',
      () {
        final transport = buildRepo().state.transport;
        expect(transport.tempoBpm, 0);
        expect(transport.tempoSource, TempoSource.none);
        expect(transport.tsNum, 4);
        expect(transport.tsDen, 4);
        expect(transport.syncTempo, isTrue);
        expect(transport.quantizeDiv, GridDivision.off);
        expect(transport.loopBars, 0);
        expect(transport.currentBeat, 0);
        expect(transport.clickMode, ClickMode.off);
        expect(transport.clickMask, 0);
        expect(transport.clickVolume, 1);
        expect(transport.countInBars, 0);
        expect(transport.countingIn, isFalse);
        expect(transport.countInBeatsLeft, 0);
        expect(transport.looperMode, LooperMode.multi);
        expect(transport.primaryTrack, -1);
      },
    );
  });

  group('applySession', () {
    /// A snapshot with [count] settled-empty tracks (the post-clear state), so
    /// the apply's settle wait passes immediately.
    EngineSnapshot clearedSnapshot(int count) => EngineSnapshot(
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
      tracks: [for (var i = 0; i < count; i++) const TrackSnapshot.empty()],
    );

    /// A single-lane (lane 0) rig track holding one live layer of [pcm].
    SessionRigTrack rigTrack(
      int channel,
      Float32List pcm, {
      double volume = 1,
      bool muted = false,
      int outputMask = 0x3,
      int inputChannel = 0,
      int lengthPresetBars = 0,
      bool oneShot = false,
    }) => SessionRigTrack(
      channel: channel,
      lengthPresetBars: lengthPresetBars,
      oneShot: oneShot,
      lanes: [
        SessionRigLane(
          lane: 0,
          layers: [pcm],
          volume: volume,
          muted: muted,
          outputMask: outputMask,
          inputChannel: inputChannel,
        ),
      ],
    );

    test(
      'clears every track, imports stems, commits, and applies mix',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        final pcm = Float32List.fromList([1, 1, 1, 1]);
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [rigTrack(0, pcm, volume: 0.5, muted: true)],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(
          engine.calls,
          containsAllInOrder(<String>[
            'clear',
            'clear',
            'importLayer',
            'finalizeLayers',
            'commitSession',
            'setLaneVolume',
            'setLaneMute',
          ]),
        );
        expect(engine.importedTracks[0], pcm);
        expect(engine.committedBaseFrames, 4);
        expect(engine.laneVol[(0, 0)], 0.5);
        expect(engine.laneMute[(0, 0)], isTrue);
      },
    );

    test('an empty rig imports nothing and establishes no master', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      expect(engine.calls, isNot(contains('importLayer')));
      expect(engine.calls, isNot(contains('commitSession')));
      expect(engine.committedBaseFrames, isNull);
    });

    test('a restart after apply replays the LOADED mix, never the pre-load '
        'caches (F2a/F2b)', () async {
      engine.nextSnapshot = clearedSnapshot(3);
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        // Pre-load rig: remembered volume + mute on track 2.
        ..setLaneVolume(0.9, channel: 2, lane: 0)
        ..setLaneMute(muted: true, channel: 2, lane: 0);
      addTearDown(repo.dispose);

      await repo.applySession(
        SessionRig(
          baseLengthFrames: 4,
          tracks: [
            rigTrack(0, Float32List.fromList([1, 1, 1, 1]), volume: 0.5),
          ],
        ),
        clearPollInterval: Duration.zero,
      );

      // A device restart replays only the loaded session's mix.
      engine.laneVol.clear();
      engine.laneMute.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());

      expect(engine.laneVol, {(0, 0): 0.5});
      expect(engine.laneMute, {(0, 0): false});
    });

    test(
      'resets a stale length preset to AUTO when the loaded session leaves '
      'it undefined (A6)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          // A live/prior session left track 0 at a 4-bar preset.
          ..setTrackLengthPreset(channel: 0, bars: 4);
        addTearDown(repo.dispose);
        expect(engine.trackLengthPreset[0], 4);

        // The loaded session's track 0 has content but no preset (AUTO),
        // and it says nothing at all about track 1.
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackLengthPreset[0], 0);
        expect(engine.trackLengthPreset[1], 0);

        // A restart replays only the loaded (AUTO) value, not the stale 4.
        engine.trackLengthPreset.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackLengthPreset.containsKey(0), isFalse);
      },
    );

    test(
      "applies the loaded session's own nonzero length preset per track "
      '(A6)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(
                0,
                Float32List.fromList([1, 1, 1, 1]),
                lengthPresetBars: 8,
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackLengthPreset[0], 8);
      },
    );

    test(
      'resets a stale one-shot flag when the loaded session leaves it '
      'undefined (B5c) — mirrors the A6 length-preset reset above, since '
      'a_one_shot survives `clear` by the same "setting, not content" rule',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          // A live/prior session left track 0 marked One Shot.
          ..setOneShot(channel: 0, oneShot: true);
        addTearDown(repo.dispose);
        expect(engine.trackOneShot[0], isTrue);

        // The loaded session's track 0 has content but is not One Shot, and
        // it says nothing at all about track 1.
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackOneShot[0], isFalse);
        expect(engine.trackOneShot[1], isFalse);

        // A restart replays only the loaded (off) value, not the stale true.
        engine.trackOneShot.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackOneShot.containsKey(0), isFalse);
      },
    );

    test(
      "applies the loaded session's own one-shot flag per track (B5c)",
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1]), oneShot: true),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackOneShot[0], isTrue);
      },
    );

    test(
      'restores a One Shot flag pre-armed on a CONTENT-LESS channel via '
      'rig.oneShotChannels (independent review of #295): channel 1 has no '
      'SessionRigTrack (no content), so only the session-level set can '
      'restore it — a plain per-track restore would silently drop it',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            oneShotChannels: const {1},
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackOneShot[0], isFalse);
        expect(engine.trackOneShot[1], isTrue);

        // Restored through the remembered cache too, so a restart replays it.
        engine.trackOneShot.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackOneShot[1], isTrue);
      },
    );

    test(
      'ignores an out-of-range channel in rig.oneShotChannels rather than '
      'pushing an invalid channel to the engine (a manifest saved on a '
      'build with more physical tracks than this engine)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            oneShotChannels: const {7},
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackOneShot.containsKey(7), isFalse);
      },
    );

    test(
      'ignores an out-of-range rig.primaryTrack rather than pushing an '
      'invalid channel to the engine or poisoning the re-apply cache '
      '(a manifest saved on a build with more physical tracks than this '
      'engine)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            primaryTrack: 7,
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.lastCrownedChannel, isNull);
      },
    );

    test(
      "applies the loaded session's looper mode and crown (B5c)",
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            looperMode: LooperMode.band,
            primaryTrack: 1,
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.lastLooperMode, LooperMode.band);
        expect(engine.lastCrownedChannel, 1);
      },
    );

    test(
      'pushes the looper mode BEFORE any content is imported, so a '
      "content-bearing session's mode is never silently dropped by the D4 "
      'content lock (B5c)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);
        // `startEngine`'s own re-apply cascade (independent review of #295)
        // pushes a `setLooperMode` call of its own BEFORE `applySession` ever
        // runs — leaving it in `engine.calls` would let `indexOf` resolve to
        // that pre-existing call instead of `applySession`'s own, making
        // `modeIndex < importIndex` trivially true regardless of where
        // `applySession` actually places its mode push. Clear it first, like
        // every other test in this file that asserts on `engine.calls` after
        // `startEngine` (e.g. the effects test above).
        engine.calls.clear();

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            looperMode: LooperMode.sync,
          ),
          clearPollInterval: Duration.zero,
        );

        final modeIndex = engine.calls.indexOf('setLooperMode');
        final importIndex = engine.calls.indexOf('importLayer');
        expect(modeIndex, greaterThanOrEqualTo(0));
        expect(importIndex, greaterThanOrEqualTo(0));
        expect(modeIndex, lessThan(importIndex));
      },
    );

    test(
      'a session load resets the primary-track RE-APPLY CACHE when it '
      'defines no crown, even though the live engine keeps a prior crown '
      '(B5c, D18: no un-crown call exists on the live engine)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          // A live/prior session crowned track 1.
          ..crownPrimary(channel: 1);
        addTearDown(repo.dispose);
        expect(engine.lastCrownedChannel, 1);

        // The loaded session defines no crown at all.
        engine.lastCrownedChannel = null;
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        // No new crownPrimary call was pushed to the LIVE engine — D18's "no
        // un-crown call" means the prior crown is not (and cannot be) undone
        // here. This is the documented limitation, not a bug.
        expect(engine.lastCrownedChannel, isNull);

        // But the re-apply CACHE was reset: a subsequent restart does not
        // resurrect the stale crown.
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.lastCrownedChannel, isNull);
      },
    );

    test(
      'a session load with no crown reports NO primary track to the UI even '
      'when the raw engine snapshot still reflects a prior crown '
      '(independent review of #295, D18 stale-crown leak fix): '
      'TransportState.primaryTrack must project from the reset-aware cache, '
      'not the raw snapshot field the engine can never un-set',
      () async {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          // A live/prior session crowned track 1.
          ..crownPrimary(channel: 1);
        addTearDown(repo.dispose);

        // The loaded session defines no crown at all — but, matching D18's
        // "no un-crown call exists", the RAW engine snapshot keeps reporting
        // the prior crown for the rest of this test, exactly like the real
        // native engine would.
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
          tracks: [TrackSnapshot.empty(), TrackSnapshot.empty()],
          primaryTrack: 1,
        );
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        // The raw snapshot the UI would otherwise read straight off still
        // says 1 — but the projected state must not leak it.
        expect(engine.nextSnapshot.primaryTrack, 1);
        expect(repo.state.transport.primaryTrack, -1);
      },
    );

    test('resets remembered chains the rig does not define — lane and '
        'monitor (F2c)', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setMonitorEffects(
          input: 1,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        );
      addTearDown(repo.dispose);

      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      // Engine chain lengths were explicitly zeroed (leftovers can't sound).
      expect(engine.laneFxCount[(0, 0)], 0);
      expect(engine.monitorFxCount[1], 0);
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(repo.monitorEffects(1), isEmpty);

      // And a restart replays nothing stale.
      engine.laneFx.clear();
      engine.monitorFx.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.laneFx, isEmpty);
      expect(engine.monitorFx, isEmpty);
    });

    test('fully resets a leftover monitor the rig does not define — routing '
        'and mix, not just its chain (F2)', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      // Session A left input 1 enabled with custom routing / mix.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorInputEnabled(input: 1, enabled: true)
        ..setMonitorOutput(input: 1, mask: 0x4)
        ..setMonitorVolume(input: 1, volume: 0.3)
        ..setMonitorMute(input: 1, muted: true);
      addTearDown(repo.dispose);

      // Session B does not define input 1 at all.
      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      // The leftover monitor is fully reset to disabled defaults — an enabled
      // monitor from A can never keep sounding under B.
      expect(repo.monitorEnabled(1), isFalse);
      expect(repo.monitorOutput(1), 0x3);
      expect(repo.monitorVolume(1), 1);
      expect(repo.monitorMuted(1), isFalse);
      expect(engine.monitorInputEnabled[1], isFalse);
    });

    test("resets a leftover track's lane count/routing the rig omits — the "
        "engine must not keep session A's lanes for a record", () async {
      engine.nextSnapshot = clearedSnapshot(2);
      // Session A configured track 0 with two lanes recording inputs 3 and 5.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneCount(channel: 0, count: 2)
        ..setLaneInput(channel: 0, lane: 0, inputChannel: 3)
        ..setLaneInput(channel: 0, lane: 1, inputChannel: 5)
        ..setLaneOutput(channel: 0, lane: 0, mask: 0x4);
      addTearDown(repo.dispose);
      expect(engine.laneCount[0], 2);

      // Session B leaves track 0 empty (defines no track 0). `clear` does not
      // reset the engine's lane_count/routing, so without the countermand a
      // record into track 0 would record 2 lanes on inputs 3+5.
      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      // Engine reset to a single fresh lane (lane 0 records input 0 to the
      // first output pair), matching the purged cache — no session-A leftover.
      expect(engine.laneCount[0], 1);
      expect(engine.laneInput[(0, 0)], 0);
      expect(engine.laneOutput[(0, 0)], 0x3);
      expect(repo.laneCount(0), 1);
    });

    test(
      'applies the rig chains and monitors through the cached setters',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            laneEffects: {
              (1, 0): [BuiltInEffect(type: TrackEffectType.delay)],
            },
            monitors: [
              SessionRigMonitor(
                input: 0,
                enabled: true,
                outputMask: 0x1,
                volume: 0.7,
                muted: false,
                effects: [BuiltInEffect(type: TrackEffectType.reverb)],
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.laneFx[(1, 0, 0)]?.code, TrackEffectType.delay.code);
        expect(engine.laneFxCount[(1, 0)], 1);
        expect(engine.monitorFx[(0, 0)]?.code, TrackEffectType.reverb.code);
        expect(engine.monitorInputEnabled[0], isTrue);
        expect(engine.monitorOutput[0], 0x1);
        expect(engine.monitorVolume[0], 0.7);
        expect(engine.monitorMute[0], isFalse);

        // The caches are truthful: a restart reproduces the loaded chains.
        engine.laneFx.clear();
        engine.monitorFx.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.laneFx[(1, 0, 0)]?.code, TrackEffectType.delay.code);
        expect(engine.monitorFx[(0, 0)]?.code, TrackEffectType.reverb.code);
      },
    );

    test(
      'retries an import that races a not-yet-acked clear, then succeeds',
      () async {
        // The engine rejects the first couple of imports (the posted-clear ack
        // race); applySession retries and the import lands rather than failing.
        engine
          ..nextSnapshot = clearedSnapshot(1)
          ..importFailCountdown = 2;
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        final pcm = Float32List.fromList([1, 1, 1, 1]);
        await repo.applySession(
          SessionRig(baseLengthFrames: 4, tracks: [rigTrack(0, pcm)]),
          clearPollInterval: Duration.zero,
        );

        expect(engine.importFailCountdown, 0); // the retries were consumed
        expect(
          engine.importedTracks[0],
          pcm,
        ); // and the import ultimately landed
      },
    );

    test('throws when the engine never settles to cleared', () async {
      engine.nextSnapshot = _playingSnapshot;
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      await expectLater(
        repo.applySession(
          const SessionRig(),
          clearPollInterval: Duration.zero,
          clearPollAttempts: 2,
        ),
        throwsStateError,
      );
    });

    test('throws when a stem import is rejected', () async {
      engine
        ..nextSnapshot = clearedSnapshot(1)
        ..importResult = EngineResult.invalid;
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      await expectLater(
        repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        ),
        throwsStateError,
      );
    });

    test(
      'imports every lane of a multi-lane track and restores per-lane mix',
      () async {
        engine.nextSnapshot = clearedSnapshot(1);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        final lane0 = Float32List.fromList([1, 1, 1, 1]);
        final lane1 = Float32List.fromList([2, 2, 2, 2]);
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              SessionRigTrack(
                channel: 0,
                lanes: [
                  SessionRigLane(
                    lane: 0,
                    layers: [lane0],
                    volume: 0.5,
                    muted: false,
                    outputMask: 0x1,
                    inputChannel: 0,
                  ),
                  SessionRigLane(
                    lane: 1,
                    layers: [lane1],
                    volume: 0.25,
                    muted: true,
                    outputMask: 0x2,
                    inputChannel: 1,
                  ),
                ],
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.importedLanes[(0, 0)], lane0);
        expect(engine.importedLanes[(0, 1)], lane1);
        expect(engine.laneVol[(0, 0)], 0.5);
        expect(engine.laneVol[(0, 1)], 0.25);
        expect(engine.laneMute[(0, 1)], isTrue);
        // Per-lane routing is restored too, not just the mix.
        expect(engine.laneInput[(0, 0)], 0);
        expect(engine.laneInput[(0, 1)], 1);
        expect(engine.laneOutput[(0, 0)], 0x1);
        expect(engine.laneOutput[(0, 1)], 0x2);
        expect(engine.laneCount[0], 2);
        expect(repo.laneCount(0), 2);
      },
    );

    test(
      'imports every overdub layer in order and finalizes the undo/redo stacks',
      () async {
        engine.nextSnapshot = clearedSnapshot(1);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        final undo0 = Float32List.fromList([1, 1, 1, 1]);
        final live = Float32List.fromList([2, 2, 2, 2]);
        final redo0 = Float32List.fromList([3, 3, 3, 3]);
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              SessionRigTrack(
                channel: 0,
                lanes: [
                  SessionRigLane(
                    lane: 0,
                    layers: [undo0, live, redo0],
                    volume: 1,
                    muted: false,
                    outputMask: 0x3,
                    inputChannel: 0,
                    undoCount: 1,
                    redoCount: 1,
                  ),
                ],
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.importedLayers[(0, 0, 0)], undo0);
        expect(engine.importedLayers[(0, 0, 1)], live);
        expect(engine.importedLayers[(0, 0, 2)], redo0);
        // The reconstructed stacks are published with the shared depths.
        expect(engine.finalizedLayers[0], (1, 1));
      },
    );
  });

  group('chain and monitor read accessors', () {
    test(
      'allLaneEffects and allMonitors expose the remembered chains',
      () {
        final repo = buildRepo()
          ..setLaneEffects(
            channel: 1,
            lane: 2,
            effects: [BuiltInEffect(type: TrackEffectType.drive)],
          )
          ..setMonitorEffects(
            input: 3,
            effects: [BuiltInEffect(type: TrackEffectType.echo)],
          );
        addTearDown(repo.dispose);

        final lanes = repo.allLaneEffects();
        expect(lanes.keys, [(1, 2)]);
        expect(
          (lanes[(1, 2)]!.single as BuiltInEffect).type,
          TrackEffectType.drive,
        );
        final monitors = repo.allMonitors();
        expect(monitors.keys, [3]);
        expect(
          (monitors[3]!.effects.single as BuiltInEffect).type,
          TrackEffectType.echo,
        );
      },
    );

    test('allMonitors captures an enabled DRY monitor (no FX chain)', () {
      // The regression that dropped dry monitors on save: an enabled input with
      // an empty chain must still be enumerated so it round-trips through a
      // session save/load.
      final repo = buildRepo()
        ..setMonitorInputEnabled(input: 2, enabled: true)
        ..setMonitorOutput(input: 2, mask: 0x2);
      addTearDown(repo.dispose);

      final monitors = repo.allMonitors();
      expect(monitors.keys, [2]);
      expect(monitors[2]!.enabled, isTrue);
      expect(monitors[2]!.outputMask, 0x2);
      expect(monitors[2]!.effects, isEmpty);
    });

    test('allMonitors omits inputs equal to the disabled default', () {
      // Touching a monitor back to the default (or a no-op setter) leaves no
      // meaningful state, so it must not bloat the enumeration / bundle.
      final repo = buildRepo()
        ..setMonitorInputEnabled(input: 1, enabled: true)
        ..setMonitorInputEnabled(input: 1, enabled: false)
        ..setMonitorOutput(input: 1, mask: 0x3) // the default mask
        ..setMonitorVolume(input: 1, volume: 1) // unity (default)
        ..setMonitorMute(input: 1, muted: false); // default
      addTearDown(repo.dispose);

      expect(repo.allMonitors(), isEmpty);
    });

    test('allMonitors captures volume / mute / output-varied monitors', () {
      final repo = buildRepo()
        ..setMonitorVolume(input: 0, volume: 0.4)
        ..setMonitorMute(input: 1, muted: true)
        ..setMonitorOutput(input: 2, mask: 0x1);
      addTearDown(repo.dispose);

      final monitors = repo.allMonitors();
      expect(monitors.keys.toSet(), {0, 1, 2});
      expect(monitors[0]!.volume, closeTo(0.4, 1e-6));
      expect(monitors[1]!.muted, isTrue);
      expect(monitors[2]!.outputMask, 0x1);
    });

    test(
      'monitor config getters read the remembered intent (with defaults)',
      () {
        final repo = buildRepo();
        addTearDown(repo.dispose);

        expect(repo.monitorEnabled(0), isFalse);
        expect(repo.monitorOutput(0), 0x3);
        expect(repo.monitorVolume(0), 1);
        expect(repo.monitorMuted(0), isFalse);

        repo
          ..setMonitorInputEnabled(input: 0, enabled: true)
          ..setMonitorOutput(input: 0, mask: 0x1)
          ..setMonitorVolume(input: 0, volume: 0.4)
          ..setMonitorMute(input: 0, muted: true);

        expect(repo.monitorEnabled(0), isTrue);
        expect(repo.monitorOutput(0), 0x1);
        expect(repo.monitorVolume(0), 0.4);
        expect(repo.monitorMuted(0), isTrue);
      },
    );
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

    test(
      'a reconnect re-applies the remembered rig (lanes + monitors)',
      () async {
        engine.nextSnapshot = runningSnapshot(devicePresent: true);
        final repo = buildSupervised()
          ..startEngine(const EngineConfig(playbackDeviceId: 'out-1'))
          // Stage some live rig state: a monitor enable + a lane routing.
          ..setMonitorInputEnabled(input: 0, enabled: true)
          ..setLaneOutput(channel: 0, lane: 0, mask: 0x2);
        final sub = repo.looperState.listen((_) {});
        addTearDown(sub.cancel);
        await Future<void>.delayed(Duration.zero);

        final monitorReapplyBefore = engine.calls
            .where((c) => c == 'setMonitorInputEnabled')
            .length;
        final laneReapplyBefore = engine.calls
            .where((c) => c == 'setLaneOutput')
            .length;

        // Device lost, then reappears → reconnect.
        engine.nextSnapshot = runningSnapshot(devicePresent: false);
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);
        engine.devices = const [pinned];
        reconnectTicker.add(null);
        await Future<void>.delayed(Duration.zero);

        expect(startCount(), 2); // reconnected
        // The reconnect went through startEngine, so the freshly-started engine
        // received the remembered rig again — it did not come back at defaults.
        expect(
          engine.calls.where((c) => c == 'setMonitorInputEnabled').length,
          greaterThan(monitorReapplyBefore),
        );
        expect(
          engine.calls.where((c) => c == 'setLaneOutput').length,
          greaterThan(laneReapplyBefore),
        );
      },
    );

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
