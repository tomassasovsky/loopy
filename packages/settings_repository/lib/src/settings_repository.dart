import 'package:local_storage_client/local_storage_client.dart';

/// Persists user/device settings via a [KeyValueStore].
///
/// Currently stores the per-device record-offset latency calibration so a
/// measured value is remembered across runs. Latency depends on the device,
/// sample rate, and buffer size, so all three form the key.
class SettingsRepository {
  /// Creates a [SettingsRepository] backed by [store].
  const SettingsRepository({required KeyValueStore store}) : _store = store;

  final KeyValueStore _store;

  String _latencyKey(String device, int sampleRate, int bufferFrames) =>
      'latency_offset.$device.$sampleRate.$bufferFrames';

  /// Loads the saved record-offset (frames) for the given device profile, or
  /// `null` if none has been stored.
  Future<int?> loadLatencyOffsetFrames({
    required String device,
    required int sampleRate,
    required int bufferFrames,
  }) => _store.getInt(_latencyKey(device, sampleRate, bufferFrames));

  /// Saves the record-offset (frames) for the given device profile.
  Future<void> saveLatencyOffsetFrames({
    required String device,
    required int sampleRate,
    required int bufferFrames,
    required int frames,
  }) => _store.setInt(_latencyKey(device, sampleRate, bufferFrames), frames);

  static const String _uiModeKey = 'ui_mode';

  /// Loads the saved UI-mode name, or `null` if none has been stored.
  ///
  /// Tolerates a legacy value of a different type (an earlier build stored the
  /// mode as an int): the stale key is dropped and `null` is returned rather
  /// than throwing a type-cast error from the store.
  Future<String?> loadUiMode() async {
    try {
      return await _store.getString(_uiModeKey);
    } on Object {
      await _store.remove(_uiModeKey);
      return null;
    }
  }

  /// Saves the UI-mode [name].
  Future<void> saveUiMode(String name) => _store.setString(_uiModeKey, name);

  String _trackNameKey(int channel) => 'track_name.$channel';

  /// Loads the custom display name for track [channel], or `null` if unset.
  Future<String?> loadTrackName(int channel) =>
      _store.getString(_trackNameKey(channel));

  /// Saves the custom display [name] for track [channel].
  Future<void> saveTrackName(int channel, String name) =>
      _store.setString(_trackNameKey(channel), name);
}
