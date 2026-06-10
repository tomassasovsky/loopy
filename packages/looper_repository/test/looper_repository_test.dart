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
        ..startEngine(const EngineConfig(passthrough: true))
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
      expect(engine.lastConfig?.passthrough, isTrue);
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

    test('custom monitor masks are deferred until running, then applied', () {
      final repo = buildRepo()
        ..setMonitorInputMask(0x2)
        ..setMonitorOutputMask(0x1);
      expect(engine.lastMonitorInputMask, isNull);

      repo.startEngine(const EngineConfig());
      expect(engine.lastMonitorInputMask, 0x2);
      expect(engine.lastMonitorOutputMask, 0x1);
    });

    test("following a track mirrors that track's masks to the monitor", () {
      engine.nextSnapshot = _playingSnapshot; // track 0 mask 0x2 in / 0x2 out
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorFollowTrack(0);
      expect(engine.lastMonitorInputMask, 0x2);
      expect(engine.lastMonitorOutputMask, 0x2);

      // Editing the followed track's routing updates the monitor too.
      repo.setInputMask(channel: 0, mask: 0x1);
      expect(engine.lastMonitorInputMask, 0x1);
      repo.setOutputMask(channel: 0, mask: 0x3);
      expect(engine.lastMonitorOutputMask, 0x3);

      // A non-followed track's edits do not touch the monitor.
      repo.setInputMask(channel: 1, mask: 0x2);
      expect(engine.lastMonitorInputMask, 0x1); // unchanged
    });

    test('switching back to custom restores the custom masks', () {
      buildRepo()
        ..setMonitorInputMask(0x2)
        ..setMonitorOutputMask(0x1)
        ..startEngine(const EngineConfig())
        ..setMonitorFollowTrack(0)
        ..setMonitorFollowTrack(null);
      expect(engine.lastMonitorInputMask, 0x2);
      expect(engine.lastMonitorOutputMask, 0x1);
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

    test('setInputMask forwards channel and mask to the engine', () {
      buildRepo().setInputMask(channel: 2, mask: 0x3);
      expect(engine.calls, contains('setInputMask'));
      expect(engine.lastChannel, 2);
      expect(engine.lastInputMask, 0x3);
    });

    test('setOutputMask forwards channel and mask to the engine', () {
      buildRepo().setOutputMask(channel: 1, mask: 0x5);
      expect(engine.calls, contains('setOutputMask'));
      expect(engine.lastChannel, 1);
      expect(engine.lastOutputMask, 0x5);
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
