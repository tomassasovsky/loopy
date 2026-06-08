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
}
