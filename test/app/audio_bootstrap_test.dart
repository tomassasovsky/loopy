import 'package:flutter/foundation.dart';
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
    late FakeKeyValueStore store;

    setUp(() {
      engine = FakeAudioEngine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      );
      store = FakeKeyValueStore();
      settings = SettingsRepository(store: store);
      addTearDown(repository.dispose);
    });

    group('first run (no saved config)', () {
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      const asioDriver = AudioDevice(
        id: 'Focusrite USB ASIO',
        name: 'Focusrite USB ASIO',
        isDefault: false,
        isInput: false,
        inputChannels: 18,
        outputChannels: 20,
        sampleRates: [48000, 96000],
        bufferSizes: [128, 256],
      );

      test('macOS/Linux opens the system default and persists it', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

        final result = await tryAutoStartEngine(
          repository: repository,
          settings: settings,
        );

        expect(result.started, isTrue);
        expect(engine.startCalls, 1);
        // A zero-config open (sample rate / buffer left at the device default).
        expect(engine.lastConfig, const EngineConfig());
        // Persisted so the next launch takes the saved-config path.
        expect(await settings.loadAudioConfig(), isNotNull);
      });

      test('macOS/Linux lands stopped when the default open fails', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        engine.startResult = EngineResult.device;

        final result = await tryAutoStartEngine(
          repository: repository,
          settings: settings,
        );

        expect(result.started, isFalse);
      });

      test('Windows starts on the first ASIO driver and caches it', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        engine.asioDrivers = const [asioDriver];

        final result = await tryAutoStartEngine(
          repository: repository,
          settings: settings,
        );

        expect(result.started, isTrue);
        // The enumerated list is returned for the cubit's picker cache.
        expect(result.asioDrivers, const [asioDriver]);
        expect(engine.lastConfig?.backend, AudioBackend.asio);
        expect(engine.lastConfig?.asioDriver, 'Focusrite USB ASIO');
        expect(engine.lastConfig?.sampleRate, 48000);
        expect(engine.lastConfig?.bufferFrames, 128);
        final saved = await settings.loadAudioConfig();
        expect(saved?.backend, AudioBackend.asio);
        expect(saved?.asioDriver, 'Focusrite USB ASIO');
      });

      test('Windows with no ASIO driver lands stopped', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        engine.asioDrivers = const [];

        final result = await tryAutoStartEngine(
          repository: repository,
          settings: settings,
        );

        expect(result.started, isFalse);
        expect(engine.startCalls, 0);
      });

      test('Windows lands stopped when the ASIO driver open fails', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        engine
          ..asioDrivers = const [asioDriver]
          ..startResult = EngineResult.device;

        final result = await tryAutoStartEngine(
          repository: repository,
          settings: settings,
        );

        expect(result.started, isFalse);
        // The drivers are still enumerated and returned for the picker cache.
        expect(result.asioDrivers, const [asioDriver]);
      });
    });

    test('restores saved per-track routing on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      // Save lane-0 routing for channel 1 only; channel 0 has none (exercises
      // the null-guard skip in the restore loop).
      await settings.saveLaneInput(1, 0, 1);
      await settings.saveLaneOutput(1, 0, 0x4);
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

      expect(started.started, isTrue);
      // Only channel 1 had saved routing, restored onto lane 0.
      expect(engine.laneInput[(1, 0)], 1);
      expect(engine.laneOutput[(1, 0)], 0x4);
    });

    test('restores saved per-lane effects on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      // Track 0 lane 0 = a two-effect chain (filter, then delay with a feedback
      // override); track 1 has no saved chain (exercises the empty skip).
      await settings.saveLaneEffects(
        0,
        0,
        encodeTrackEffects([
          TrackEffect(type: TrackEffectType.filter),
          TrackEffect(
            type: TrackEffectType.delay,
            params: const [0.3, 0.42, 0.5],
          ),
        ]),
      );
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
        tracks: [TrackSnapshot.empty()],
      );

      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.laneFx[(0, 0, 0)], TrackEffectType.filter);
      expect(engine.laneFx[(0, 0, 1)], TrackEffectType.delay);
      expect(engine.laneFxCount[(0, 0)], 2);
      expect(engine.laneFxParam[(0, 0, 1, 1)], 0.42);
    });

    test('restores a saved multi-lane setup on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      // Track 0 has two lanes; lane 1 carries its own input, output, mix, and
      // effect chain that must be restored alongside lane 0.
      await settings.saveLaneCount(0, 2);
      await settings.saveLaneInput(0, 1, 2);
      await settings.saveLaneOutput(0, 1, 0x2);
      await settings.saveLaneVolume(0, 1, 0.4);
      await settings.saveLaneMute(0, 1, muted: true);
      await settings.saveLaneEffects(
        0,
        1,
        encodeTrackEffects([TrackEffect(type: TrackEffectType.tremolo)]),
      );
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
        tracks: [TrackSnapshot.empty()],
      );

      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.laneCount[0], 2);
      expect(engine.laneInput[(0, 1)], 2);
      expect(engine.laneOutput[(0, 1)], 0x2);
      expect(engine.laneVol[(0, 1)], 0.4);
      expect(engine.laneMute[(0, 1)], isTrue);
      expect(engine.laneFx[(0, 1, 0)], TrackEffectType.tremolo);
    });

    test('starts the engine with the saved config', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 96000,
          bufferFrames: 256,
        ),
      );

      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.startCalls, 1);
      expect(engine.lastConfig?.sampleRate, 96000);
      expect(engine.lastConfig?.bufferFrames, 256);
      // Channel counts left at 0 (device default) so the interface opens with
      // all its channels; the negotiated counts come back via the snapshot.
      expect(engine.lastConfig?.inputChannels, 0);
      expect(engine.lastConfig?.outputChannels, 0);
    });

    test('relaunches into the saved ASIO backend + driver', () async {
      // The auto-start config assembly is duplicated from the cubit's
      // _engineConfig; this guards against the two diverging on backend/driver.
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          backend: AudioBackend.asio,
          asioDriver: 'Focusrite USB ASIO',
        ),
      );

      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.lastConfig?.backend, AudioBackend.asio);
      expect(engine.lastConfig?.asioDriver, 'Focusrite USB ASIO');
    });

    test('restores the saved latency offset for the device', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
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
          ),
        );
        // No saved latency offset for this profile.

        await tryAutoStartEngine(repository: repository, settings: settings);

        expect(engine.measureLatencyCalls, 1);
        expect(engine.lastRecordOffset, isNull); // restored nothing, measured
      },
    );

    test(
      'a saved capture device wins over loopback auto-routing',
      () async {
        // A routable loopback exists (as on any PipeWire host), but the saved
        // config pins a real input device: capture must not be auto-routed to
        // the loopback, and the loopback-driven auto-measure must be skipped.
        engine.loopback = const LoopbackInfo(
          available: true,
          kind: LoopbackKind.virtualDevice,
          deviceName: 'BlackHole',
        );
        await settings.saveAudioConfig(
          const StoredAudioConfig(
            sampleRate: 48000,
            bufferFrames: 128,
            captureDeviceId: 'clarett-in',
          ),
        );

        await tryAutoStartEngine(repository: repository, settings: settings);

        expect(engine.lastConfig?.useLoopbackCapture, isFalse);
        expect(engine.lastConfig?.captureDeviceId, 'clarett-in');
        expect(engine.measureLatencyCalls, 0);
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
        ),
      );

      final started = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
      );
      expect(started.started, isFalse);
    });
  });
}
