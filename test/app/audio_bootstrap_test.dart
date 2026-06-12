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

      expect(started, isTrue);
      // Only channel 1 had saved routing, restored onto lane 0.
      expect(engine.laneInput[(1, 0)], 1);
      expect(engine.laneOutput[(1, 0)], 0x4);
    });

    test('restores saved per-lane effects on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          monitorInput: true,
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

      expect(started, isTrue);
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
          monitorInput: true,
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

      expect(started, isTrue);
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
            monitorInput: true,
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
