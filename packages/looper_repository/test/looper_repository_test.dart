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
  trackState: TrackState.playing,
  trackVolume: 0.8,
  trackLengthFrames: 96000,
  trackUndoDepth: 1,
  trackRms: 0.3,
  trackPeak: 0.5,
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

    test('engineVersion is forwarded', () {
      final repo = buildRepo();
      expect(repo.engineVersion, 'fake-engine');
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
