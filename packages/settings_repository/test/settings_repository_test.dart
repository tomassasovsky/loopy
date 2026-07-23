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

  group('track names', () {
    test('round-trips a saved name', () async {
      await repository.saveTrackName(2, 'VOX');
      expect(await repository.loadTrackName(2), 'VOX');
      expect(await repository.loadTrackName(0), isNull);
    });
  });

  group('lane routing', () {
    test('returns sensible defaults when nothing is stored', () async {
      expect(await repository.loadLaneCount(0), 1);
      expect(await repository.loadLaneInput(0, 0), isNull);
      expect(await repository.loadLaneOutput(0, 0), isNull);
      expect(await repository.loadLaneVolume(0, 0), isNull);
      expect(await repository.loadLaneMute(0, 0), isNull);
    });

    test('round-trips a saved lane count per track', () async {
      await repository.saveLaneCount(1, 3);
      expect(await repository.loadLaneCount(1), 3);
      expect(await repository.loadLaneCount(0), 1);
    });

    test('round-trips per-lane input / output / volume / mute', () async {
      await repository.saveLaneInput(1, 0, 2);
      await repository.saveLaneOutput(1, 0, 0x5);
      await repository.saveLaneVolume(1, 0, 0.6);
      await repository.saveLaneMute(1, 0, muted: true);
      expect(await repository.loadLaneInput(1, 0), 2);
      expect(await repository.loadLaneOutput(1, 0), 0x5);
      expect(await repository.loadLaneVolume(1, 0), closeTo(0.6, 1e-6));
      expect(await repository.loadLaneMute(1, 0), isTrue);
      // A different lane is independent.
      expect(await repository.loadLaneInput(1, 1), isNull);
    });
  });

  group('lane effects', () {
    test('returns null when nothing is stored', () async {
      expect(await repository.loadLaneEffects(0, 0), isNull);
    });

    test('round-trips an encoded chain per (channel, lane)', () async {
      await repository.saveLaneEffects(1, 0, '[{"type":3}]');
      expect(await repository.loadLaneEffects(1, 0), '[{"type":3}]');
      expect(await repository.loadLaneEffects(1, 1), isNull);
      expect(await repository.loadLaneEffects(0, 0), isNull);
    });
  });

  group('monitor (single chain)', () {
    test('per-input enable flag defaults to null and round-trips', () async {
      expect(await repository.loadMonitorInputEnabled(0), isNull);
      await repository.saveMonitorInputEnabled(0, enabled: true);
      expect(await repository.loadMonitorInputEnabled(0), isTrue);
      expect(await repository.loadMonitorInputEnabled(1), isNull);
    });

    test('output mask defaults to null and round-trips per input', () async {
      expect(await repository.loadMonitorOutput(0), isNull);
      await repository.saveMonitorOutput(0, 0x2);
      expect(await repository.loadMonitorOutput(0), 0x2);
      expect(await repository.loadMonitorOutput(1), isNull);
    });

    test('volume round-trips per input', () async {
      expect(await repository.loadMonitorVolume(0), isNull);
      await repository.saveMonitorVolume(0, 0.5);
      expect(await repository.loadMonitorVolume(0), 0.5);
    });

    test('mute round-trips per input', () async {
      expect(await repository.loadMonitorMute(0), isNull);
      await repository.saveMonitorMute(0, muted: true);
      expect(await repository.loadMonitorMute(0), isTrue);
    });

    test('effects round-trip the encoded chain per input', () async {
      expect(await repository.loadMonitorEffects(0), isNull);
      await repository.saveMonitorEffects(0, '[{"type":1}]');
      expect(await repository.loadMonitorEffects(0), '[{"type":1}]');
      expect(await repository.loadMonitorEffects(1), isNull);
    });

    test('the v2 migration flag defaults to false and round-trips', () async {
      expect(await repository.loadMonitorMigratedV2(), isFalse);
      await repository.saveMonitorMigratedV2();
      expect(await repository.loadMonitorMigratedV2(), isTrue);
    });

    test('the v3 migration flag defaults to false and round-trips', () async {
      expect(await repository.loadMonitorMigratedV3(), isFalse);
      await repository.saveMonitorMigratedV3();
      expect(await repository.loadMonitorMigratedV3(), isTrue);
    });
  });

  group('output gate', () {
    test('absence means enabled; only off entries are written', () async {
      // Default-on: no key => null (the caller reads as enabled).
      expect(await repository.loadOutputEnabled(0), isNull);

      // Disabling writes false.
      await repository.saveOutputEnabled(0, enabled: false);
      expect(await repository.loadOutputEnabled(0), isFalse);

      // Re-enabling REMOVES the key (self-cleaning, absence == enabled).
      await repository.saveOutputEnabled(0, enabled: true);
      expect(await repository.loadOutputEnabled(0), isNull);
    });

    test('clearMonitorLaneKeys removes the prior multi-lane keys', () async {
      await repository.saveMonitorLaneCount(0, 2);
      await repository.saveMonitorLaneOutput(0, 0, 0x1);
      await repository.saveMonitorLaneOutput(0, 1, 0x2);

      await repository.clearMonitorLaneKeys(0, 2);

      expect(await repository.loadMonitorLaneCount(0), isNull);
      expect(await repository.loadMonitorLaneOutput(0, 0), isNull);
      expect(await repository.loadMonitorLaneOutput(0, 1), isNull);
    });
  });

  group('legacy monitor keys (migration only)', () {
    test('legacy single-route routing round-trips', () async {
      expect(await repository.loadMonitorInput(0), isNull);
      await repository.saveMonitorInput(0, enabled: true, outputMask: 0x2);
      expect(await repository.loadMonitorInput(0), (true, 0x2));
    });

    test('clearLegacyMonitorInput removes the four legacy keys', () async {
      await repository.saveMonitorInput(0, enabled: true, outputMask: 0x2);
      await repository.clearLegacyMonitorInput(0);
      expect(await repository.loadMonitorInput(0), isNull);
      expect(await repository.loadMonitorInputDry(0), 0);
      expect(await repository.loadMonitorInputVolume(0), isNull);
      expect(await repository.loadMonitorInputEffects(0), isNull);
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
      );
      await repository.saveAudioConfig(config);
      expect(await repository.loadAudioConfig(), config);
    });

    test('does not write the removed legacy audio.monitor_input key', () async {
      // Monitoring is now the per-input routing graph; saving an audio config
      // must never resurrect the legacy global flag.
      await repository.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      expect(store.values.containsKey('audio.monitor_input'), isFalse);
    });

    test('round-trips requested channel counts', () async {
      const config = StoredAudioConfig(
        sampleRate: 48000,
        bufferFrames: 128,
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

    test('does not write the removed audio.exclusive key', () async {
      // OS-exclusive mode is gone (Windows is ASIO-only); saving must never
      // resurrect the legacy key.
      await repository.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      expect(store.values.containsKey('audio.exclusive'), isFalse);
    });

    test('round-trips the backend and ASIO driver', () async {
      const config = StoredAudioConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        backend: AudioBackend.asio,
        asioDriver: 'Focusrite USB ASIO',
      );
      await repository.saveAudioConfig(config);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.backend, AudioBackend.asio);
      expect(loaded?.asioDriver, 'Focusrite USB ASIO');
    });

    test('defaults backend to miniaudio and driver empty when unset', () async {
      await store.setInt('audio.sample_rate', 44100);
      await store.setInt('audio.buffer_frames', 64);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.backend, AudioBackend.miniaudio);
      expect(loaded?.asioDriver, '');
    });

    test('resolves an unknown stored backend name to miniaudio', () async {
      // Forward-compat: a newer build may write a backend name this build does
      // not know. It must resolve to miniaudio rather than throwing.
      await store.setInt('audio.sample_rate', 48000);
      await store.setInt('audio.buffer_frames', 128);
      await store.setString('audio.backend', 'some_future_backend');
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.backend, AudioBackend.miniaudio);
    });

    test(
      'ignores legacy audio.merge_to_mono / monitor_input keys on load',
      () async {
        // Both features were removed; an old store may still carry the keys.
        // Loading must succeed and read neither into the stored config.
        await store.setInt('audio.sample_rate', 48000);
        await store.setInt('audio.buffer_frames', 128);
        await store.setBool('audio.monitor_input', value: true);
        await store.setBool('audio.merge_to_mono', value: true);
        expect(
          await repository.loadAudioConfig(),
          const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
        );
      },
    );

    test('a stale ui_mode key does not break config load', () async {
      // The UI-mode feature was removed; an old store may still carry the key.
      // Loading the audio config must succeed and never read it.
      await store.setString('ui_mode', 'desktop');
      await store.setInt('audio.sample_rate', 48000);
      await store.setInt('audio.buffer_frames', 128);
      expect(
        await repository.loadAudioConfig(),
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
    });
  });

  group('legacy monitor migration accessors', () {
    test(
      'loadLegacyMonitorInput reads the legacy audio.monitor_input key',
      () async {
        // loadAudioConfig no longer reads this key; only the migration does.
        expect(await repository.loadLegacyMonitorInput(), isNull);
        await store.setBool('audio.monitor_input', value: false);
        expect(await repository.loadLegacyMonitorInput(), isFalse);
        await store.setBool('audio.monitor_input', value: true);
        expect(await repository.loadLegacyMonitorInput(), isTrue);
      },
    );

    test('monitor-migrated flag defaults to false and round-trips', () async {
      expect(await repository.loadMonitorMigratedV1(), isFalse);
      await repository.saveMonitorMigratedV1();
      expect(await repository.loadMonitorMigratedV1(), isTrue);
    });
  });

  group('midi device', () {
    test('returns null when nothing is stored', () async {
      expect(await repository.loadMidiDevice(), isNull);
    });

    test('round-trips a saved id + name', () async {
      await repository.saveMidiDevice(id: '12345', name: 'FCB1010');
      final loaded = await repository.loadMidiDevice();
      expect(loaded?.id, '12345');
      expect(loaded?.name, 'FCB1010');
    });

    test('defaults the name to empty when only the id was stored', () async {
      await store.setString('midi.input_device_id', 'port-1');
      final loaded = await repository.loadMidiDevice();
      expect(loaded?.id, 'port-1');
      expect(loaded?.name, '');
    });

    test('treats an empty saved id as no selection', () async {
      await repository.saveMidiDevice(id: '', name: '');
      expect(await repository.loadMidiDevice(), isNull);
    });

    test('clearMidiDevice removes both keys', () async {
      await repository.saveMidiDevice(id: '12345', name: 'FCB1010');
      await repository.clearMidiDevice();
      expect(await repository.loadMidiDevice(), isNull);
      expect(store.values.containsKey('midi.input_device_id'), isFalse);
      expect(store.values.containsKey('midi.input_device_name'), isFalse);
    });
  });

  group('pedal output device', () {
    test('returns null when nothing is stored', () async {
      expect(await repository.loadPedalOutputDevice(), isNull);
    });

    test('round-trips a saved id + name', () async {
      await repository.savePedalOutputDevice(id: 'out-7', name: 'Loopy Pedal');
      final loaded = await repository.loadPedalOutputDevice();
      expect(loaded?.id, 'out-7');
      expect(loaded?.name, 'Loopy Pedal');
    });

    test('treats an empty saved id as no selection', () async {
      await repository.savePedalOutputDevice(id: '', name: '');
      expect(await repository.loadPedalOutputDevice(), isNull);
    });

    test('clearPedalOutputDevice removes both keys', () async {
      await repository.savePedalOutputDevice(id: 'out-7', name: 'Loopy Pedal');
      await repository.clearPedalOutputDevice();
      expect(await repository.loadPedalOutputDevice(), isNull);
      expect(store.values.containsKey('pedal.output_device_id'), isFalse);
      expect(store.values.containsKey('pedal.output_device_name'), isFalse);
    });
  });

  group('pedal timing', () {
    test('long-press defaults to 500 ms and round-trips', () async {
      expect(await repository.loadPedalLongPressMs(), 500);
      await repository.savePedalLongPressMs(750);
      expect(await repository.loadPedalLongPressMs(), 750);
    });

    test(
      'clear-fade defaults to 1000 ms and round-trips (0 disables)',
      () async {
        expect(await repository.loadPedalClearFadeMs(), 1000);
        await repository.savePedalClearFadeMs(0);
        expect(await repository.loadPedalClearFadeMs(), 0);
      },
    );
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

  group('high contrast', () {
    test('defaults to off when unset', () async {
      expect(await repository.loadHighContrast(), isFalse);
    });

    test('round-trips a saved preference', () async {
      await repository.saveHighContrast(value: true);
      expect(await repository.loadHighContrast(), isTrue);
    });
  });

  group('track indicators', () {
    test('defaults to enabled when unset', () async {
      expect(await repository.loadShowTrackIndicators(), isTrue);
    });

    test('round-trips a saved preference', () async {
      await repository.saveShowTrackIndicators(value: false);
      expect(await repository.loadShowTrackIndicators(), isFalse);
    });
  });

  group('default interaction mode', () {
    test('returns null when unset', () async {
      expect(await repository.loadDefaultInteractionMode(), isNull);
    });

    test('round-trips a saved token', () async {
      await repository.saveDefaultInteractionMode('play');
      expect(await repository.loadDefaultInteractionMode(), 'play');
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

  group('record options', () {
    test('rec/dub and auto-record default off and round-trip', () async {
      expect(await repository.loadRecDub(), isFalse);
      expect(await repository.loadAutoRecord(), isFalse);
      await repository.saveRecDub(value: true);
      await repository.saveAutoRecord(value: true);
      expect(await repository.loadRecDub(), isTrue);
      expect(await repository.loadAutoRecord(), isTrue);
    });
  });

  group('track multiple', () {
    test('defaults to 0 (auto) and round-trips a fixed value', () async {
      expect(await repository.loadTrackMultiple(0), 0);
      await repository.saveTrackMultiple(0, 3);
      expect(await repository.loadTrackMultiple(0), 3);
    });
  });

  group('default multiple', () {
    test('defaults to 0 (auto) and round-trips a fixed value', () async {
      expect(await repository.loadDefaultMultiple(), 0);
      await repository.saveDefaultMultiple(2);
      expect(await repository.loadDefaultMultiple(), 2);
    });
  });

  group('track quantize override', () {
    test('defaults to null (inherit) when unset', () async {
      expect(await repository.loadTrackQuantize(0), isNull);
    });

    test('round-trips force-on, force-off, and inherit', () async {
      await repository.saveTrackQuantize(0, enabled: true);
      await repository.saveTrackQuantize(1, enabled: false);
      expect(await repository.loadTrackQuantize(0), isTrue);
      expect(await repository.loadTrackQuantize(1), isFalse);

      await repository.saveTrackQuantize(0, enabled: null);
      expect(await repository.loadTrackQuantize(0), isNull);
    });
  });

  group('tempo bpm', () {
    test('defaults to 0 (never set) when unset', () async {
      expect(await repository.loadTempoBpm(), 0);
    });

    test('round-trips a saved tempo', () async {
      await repository.saveTempoBpm(128.5);
      expect(await repository.loadTempoBpm(), 128.5);
    });
  });

  group('time signature', () {
    test('defaults to 4/4 when unset', () async {
      expect(await repository.loadTimeSignature(), (4, 4));
    });

    test('round-trips a saved signature', () async {
      await repository.saveTimeSignature(7, 8);
      expect(await repository.loadTimeSignature(), (7, 8));
    });
  });

  group('sync tempo', () {
    test('defaults to on when unset', () async {
      expect(await repository.loadSyncTempo(), isTrue);
    });

    test('round-trips a saved preference', () async {
      await repository.saveSyncTempo(value: false);
      expect(await repository.loadSyncTempo(), isFalse);
    });
  });

  group('quantize div', () {
    test('defaults to 0 (off) when unset', () async {
      expect(await repository.loadQuantizeDiv(), 0);
    });

    test('round-trips a saved enum code', () async {
      await repository.saveQuantizeDiv(3);
      expect(await repository.loadQuantizeDiv(), 3);
    });
  });

  group('click mode', () {
    test('defaults to 0 (off) when unset', () async {
      expect(await repository.loadClickMode(), 0);
    });

    test('round-trips a saved enum code', () async {
      await repository.saveClickMode(2);
      expect(await repository.loadClickMode(), 2);
    });
  });

  group('click output mask', () {
    test('defaults to 0 (no outputs) when unset', () async {
      expect(await repository.loadClickOutputMask(), 0);
    });

    test('round-trips a saved mask', () async {
      await repository.saveClickOutputMask(0x3);
      expect(await repository.loadClickOutputMask(), 0x3);
    });
  });

  group('click volume', () {
    test('defaults to 1.0 when unset', () async {
      expect(await repository.loadClickVolume(), 1.0);
    });

    test('round-trips a saved volume', () async {
      await repository.saveClickVolume(0.5);
      expect(await repository.loadClickVolume(), 0.5);
    });
  });

  group('count-in bars', () {
    test('defaults to 0 (off) when unset — the wire default, not the '
        'UI-suggested one bar', () async {
      expect(await repository.loadCountInBars(), 0);
    });

    test('round-trips a saved bar count', () async {
      await repository.saveCountInBars(2);
      expect(await repository.loadCountInBars(), 2);
    });
  });

  group('track length preset', () {
    test('defaults to 0 (AUTO) and round-trips a fixed value', () async {
      expect(await repository.loadTrackLengthPreset(0), 0);
      await repository.saveTrackLengthPreset(0, 8);
      expect(await repository.loadTrackLengthPreset(0), 8);
    });

    test('is independent per track', () async {
      await repository.saveTrackLengthPreset(0, 4);
      await repository.saveTrackLengthPreset(1, 16);
      expect(await repository.loadTrackLengthPreset(0), 4);
      expect(await repository.loadTrackLengthPreset(1), 16);
      expect(await repository.loadTrackLengthPreset(2), 0);
    });
  });

  group('StoredAudioConfig.maxLoopMinutes', () {
    test(
      'defaults to 0 (engine default) and round-trips a saved value',
      () async {
        const config = StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
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
