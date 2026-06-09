import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
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

    test('starts the engine with the saved config', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 96000,
          bufferFrames: 256,
          monitorInput: false,
          mergeToMono: false,
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
      expect(engine.lastConfig?.mergeToMono, isFalse);
      expect(engine.lastConfig?.channels, 2);
    });

    test('restores the saved latency offset for the device', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          monitorInput: true,
          mergeToMono: true,
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

    test('returns false when the engine fails to start', () async {
      engine.startResult = EngineResult.device;
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          monitorInput: true,
          mergeToMono: true,
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
