import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy_engine/loopy_engine.dart';

import 'helpers/fake_audio_engine.dart';

const _playingSnapshot = EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  channels: 2,
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
      expect(state.status.deviceName, 'Fake Device');
      expect(state.status.sampleRate, 48000);
      expect(state.status.isConnected, isTrue);
    });

    test('projects multiple tracks with their channel indices', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        channels: 2,
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
        channels: 2,
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
  });

  group('commands forward to the engine', () {
    test('each command calls the matching engine method', () {
      buildRepo()
        ..startEngine(const EngineConfig(passthrough: true))
        ..record()
        ..stopTrack()
        ..play()
        ..undo()
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

    test('engineVersion is forwarded', () {
      final repo = buildRepo();
      expect(repo.engineVersion, 'fake-engine');
    });

    test('setRecordOffset forwards to the engine', () {
      buildRepo().setRecordOffset(480);
      expect(engine.calls, contains('setRecordOffset'));
      expect(engine.lastRecordOffset, 480);
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

  group('dispose', () {
    test('disposes the engine and closes the stream', () async {
      final repo = buildRepo();
      await repo.dispose();
      expect(engine.calls, contains('dispose'));
    });
  });
}
