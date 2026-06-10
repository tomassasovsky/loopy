import 'package:flutter_test/flutter_test.dart';
import 'package:settings_repository/settings_repository.dart';

class _InMemoryStore implements KeyValueStore {
  final Map<String, Object> values = {};

  @override
  Future<int?> getInt(String key) async => values[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> setString(String key, String value) async => values[key] = value;

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<void> setBool(String key, {required bool value}) async =>
      values[key] = value;

  @override
  Future<double?> getDouble(String key) async => values[key] as double?;

  @override
  Future<void> setDouble(String key, double value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<void> clear() async => values.clear();
}

void main() {
  late _InMemoryStore store;
  late SettingsRepository repository;

  setUp(() {
    store = _InMemoryStore();
    repository = SettingsRepository(store: store);
  });

  group('latency offset', () {
    test('returns null when nothing is stored', () async {
      final value = await repository.loadLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
      );
      expect(value, isNull);
    });

    test('round-trips a saved value for a device profile', () async {
      await repository.saveLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
        frames: 480,
      );

      expect(
        await repository.loadLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
        ),
        480,
      );
    });

    test(
      'keys are distinct per device, sample rate, and buffer size',
      () async {
        await repository.saveLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
          frames: 480,
        );

        // Same device, different buffer size -> independent value.
        expect(
          await repository.loadLatencyOffsetFrames(
            device: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 256,
          ),
          isNull,
        );
        // Different device -> independent value.
        expect(
          await repository.loadLatencyOffsetFrames(
            device: 'BlackHole',
            sampleRate: 48000,
            bufferFrames: 128,
          ),
          isNull,
        );

        expect(store.values, hasLength(1));
      },
    );
  });

  group('ui mode', () {
    test('round-trips a saved mode name', () async {
      await repository.saveUiMode('bigPicture');
      expect(await repository.loadUiMode(), 'bigPicture');
    });

    test('tolerates and clears a legacy int value', () async {
      // An earlier build stored the mode as an int under the same key.
      await store.setInt('ui_mode', 1);
      expect(await repository.loadUiMode(), isNull);
      // The stale key is dropped so it does not keep failing.
      expect(store.values.containsKey('ui_mode'), isFalse);
    });
  });

  group('track names', () {
    test('round-trips a saved name', () async {
      await repository.saveTrackName(2, 'VOX');
      expect(await repository.loadTrackName(2), 'VOX');
      expect(await repository.loadTrackName(0), isNull);
    });
  });

  group('track routing', () {
    test('returns null when nothing is stored', () async {
      expect(await repository.loadTrackInputMask(0), isNull);
      expect(await repository.loadTrackOutputMask(0), isNull);
    });

    test('round-trips a saved input mask per track', () async {
      await repository.saveTrackInputMask(1, 0x3);
      expect(await repository.loadTrackInputMask(1), 0x3);
      expect(await repository.loadTrackInputMask(0), isNull);
    });

    test('round-trips a saved output mask per track', () async {
      await repository.saveTrackOutputMask(2, 0x5);
      expect(await repository.loadTrackOutputMask(2), 0x5);
      expect(await repository.loadTrackOutputMask(0), isNull);
    });
  });

  group('audio config', () {
    test('returns null on a first run (nothing saved)', () async {
      expect(await repository.loadAudioConfig(), isNull);
    });

    test('round-trips a saved config', () async {
      const config = StoredAudioConfig(
        sampleRate: 96000,
        bufferFrames: 256,
        monitorInput: false,
      );
      await repository.saveAudioConfig(config);
      expect(await repository.loadAudioConfig(), config);
    });

    test('round-trips requested channel counts', () async {
      const config = StoredAudioConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        monitorInput: true,
        inputChannels: 2,
        outputChannels: 4,
      );
      await repository.saveAudioConfig(config);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.inputChannels, 2);
      expect(loaded?.outputChannels, 4);
    });

    test('defaults channel counts to 0 (device default) when unset', () async {
      await store.setInt('audio.sample_rate', 44100);
      await store.setInt('audio.buffer_frames', 64);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.inputChannels, 0);
      expect(loaded?.outputChannels, 0);
    });

    test('round-trips pinned device ids', () async {
      const config = StoredAudioConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        monitorInput: true,
        playbackDeviceId: 'out-device-1',
        captureDeviceId: 'in-device-2',
      );
      await repository.saveAudioConfig(config);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.playbackDeviceId, 'out-device-1');
      expect(loaded?.captureDeviceId, 'in-device-2');
    });

    test('defaults device ids to empty (system default) when unset', () async {
      await store.setInt('audio.sample_rate', 44100);
      await store.setInt('audio.buffer_frames', 64);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.playbackDeviceId, '');
      expect(loaded?.captureDeviceId, '');
    });

    test(
      'defaults the toggles to true when only rate/buffer are set',
      () async {
        await store.setInt('audio.sample_rate', 44100);
        await store.setInt('audio.buffer_frames', 64);
        expect(
          await repository.loadAudioConfig(),
          const StoredAudioConfig(
            sampleRate: 44100,
            bufferFrames: 64,
            monitorInput: true,
          ),
        );
      },
    );

    test('ignores a legacy audio.merge_to_mono key on load', () async {
      // The merge-to-mono feature was removed; an old store may still carry the
      // key. Loading must succeed and simply not read it. monitorInput is set
      // to false (against the legacy bool's true) so the assertion fails if the
      // stale key were ever wired back into a real field.
      await store.setInt('audio.sample_rate', 48000);
      await store.setInt('audio.buffer_frames', 128);
      await store.setBool('audio.monitor_input', value: false);
      await store.setBool('audio.merge_to_mono', value: true);
      expect(
        await repository.loadAudioConfig(),
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          monitorInput: false,
        ),
      );
    });
  });

  group('waveform window', () {
    test('defaults to enabled when unset', () async {
      expect(await repository.loadShowWaveformWindow(), isTrue);
    });

    test('round-trips a saved preference', () async {
      await repository.saveShowWaveformWindow(value: false);
      expect(await repository.loadShowWaveformWindow(), isFalse);
    });
  });

  group('bank enabled', () {
    test('defaults to enabled when unset', () async {
      expect(await repository.loadBankEnabled(), isTrue);
    });

    test('round-trips a saved preference', () async {
      await repository.saveBankEnabled(value: true);
      expect(await repository.loadBankEnabled(), isTrue);
    });
  });

  group('default performance mode', () {
    test('returns null when unset', () async {
      expect(await repository.loadDefaultPerformanceMode(), isNull);
    });

    test('round-trips a saved token', () async {
      await repository.saveDefaultPerformanceMode('play');
      expect(await repository.loadDefaultPerformanceMode(), 'play');
    });
  });

  group('refresh rate', () {
    test('defaults to 60 Hz when unset', () async {
      expect(await repository.loadRefreshHz(), 60);
    });

    test('round-trips a saved rate', () async {
      await repository.saveRefreshHz(120);
      expect(await repository.loadRefreshHz(), 120);
    });
  });

  group('quantize', () {
    test('defaults to off when unset', () async {
      expect(await repository.loadQuantize(), isFalse);
    });

    test('round-trips a saved preference', () async {
      await repository.saveQuantize(value: true);
      expect(await repository.loadQuantize(), isTrue);
    });
  });

  group('StoredAudioConfig.maxLoopMinutes', () {
    test(
      'defaults to 0 (engine default) and round-trips a saved value',
      () async {
        const config = StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          monitorInput: true,
          maxLoopMinutes: 5,
        );
        await repository.saveAudioConfig(config);
        expect((await repository.loadAudioConfig())?.maxLoopMinutes, 5);
      },
    );

    test('defaults to 0 when only rate/buffer are set', () async {
      await store.setInt('audio.sample_rate', 48000);
      await store.setInt('audio.buffer_frames', 128);
      expect((await repository.loadAudioConfig())?.maxLoopMinutes, 0);
    });
  });
}
