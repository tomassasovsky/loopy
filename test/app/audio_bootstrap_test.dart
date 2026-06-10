import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

void main() {
  group('tryAutoStartEngine', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;
    late SettingsRepository settings;

    setUp(() {
      engine = FakeAudioEngine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      );
      settings = SettingsRepository(store: FakeKeyValueStore());
      addTearDown(repository.dispose);
    });

    test('returns false and does not start when no config is saved', () async {
      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );
      expect(started, isFalse);
      expect(engine.startCalls, 0);
    });

    test('restores saved per-track routing on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          monitorInput: true,
        ),
      );
      // Save routing for channel 1 only; channel 0 has none (exercises the
      // null-guard skip in the restore loop).
      await settings.saveTrackInputMask(1, 0x2);
      await settings.saveTrackOutputMask(1, 0x4);
      // The restore loop iterates the engine's reported tracks.
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
        tracks: [TrackSnapshot.empty(), TrackSnapshot.empty()],
      );

      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );

      expect(started, isTrue);
      // Only channel 1 had saved routing, so it is the last (and only) applied.
      expect(engine.lastInputRoutingChannel, 1);
      expect(engine.lastInputMask, 0x2);
      expect(engine.lastOutputRoutingChannel, 1);
      expect(engine.lastOutputMask, 0x4);
    });

    test('starts the engine with the saved config', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 96000,
          bufferFrames: 256,
          monitorInput: false,
        ),
      );

      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );

      expect(started, isTrue);
      expect(engine.startCalls, 1);
      expect(engine.lastConfig?.sampleRate, 96000);
      expect(engine.lastConfig?.bufferFrames, 256);
      expect(engine.lastConfig?.passthrough, isFalse);
      // Channel counts left at 0 (device default) so the interface opens with
      // all its channels; the negotiated counts come back via the snapshot.
      expect(engine.lastConfig?.inputChannels, 0);
      expect(engine.lastConfig?.outputChannels, 0);
    });

    test('restores the saved latency offset for the device', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          monitorInput: true,
        ),
      );
      // Saved under the profile the running engine reports (the fake's default
      // snapshot has sample rate / buffer 0, device 'Fake Device').
      await settings.saveLatencyOffsetFrames(
        device: 'Fake Device',
        sampleRate: 0,
        bufferFrames: 0,
        frames: 720,
      );

      await tryAutoStartEngine(repository: repository, settings: settings);

      expect(engine.lastRecordOffset, 720);
    });

    test(
      'auto-measures when no saved offset and loopback is routable',
      () async {
        engine.loopback = const LoopbackInfo(
          available: true,
          kind: LoopbackKind.virtualDevice,
          deviceName: 'BlackHole',
        );
        await settings.saveAudioConfig(
          const StoredAudioConfig(
            sampleRate: 48000,
            bufferFrames: 128,
            monitorInput: true,
          ),
        );
        // No saved latency offset for this profile.

        await tryAutoStartEngine(repository: repository, settings: settings);

        expect(engine.measureLatencyCalls, 1);
        expect(engine.lastRecordOffset, isNull); // restored nothing, measured
      },
    );

    test(
      'auto-measures when no saved offset and the device has loopback channels',
      () async {
        // No routable loopback device, but the opened interface reports
        // dedicated loopback channels via the excluded-input mask.
        engine.nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          excludedInputMask: 0x30,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: LatencyState.idle,
          measuredLatencyMs: -1,
        );
        await settings.saveAudioConfig(
          const StoredAudioConfig(
            sampleRate: 48000,
            bufferFrames: 128,
            monitorInput: true,
          ),
        );

        await tryAutoStartEngine(repository: repository, settings: settings);

        expect(engine.measureLatencyCalls, 1);
      },
    );

    test('returns false when the engine fails to start', () async {
      engine.startResult = EngineResult.device;
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          monitorInput: true,
        ),
      );

      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );
      expect(started, isFalse);
    });
  });
}
