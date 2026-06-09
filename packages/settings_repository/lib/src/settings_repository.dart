import 'package:flutter/foundation.dart';
import 'package:local_storage_client/local_storage_client.dart';

/// A persisted audio device configuration, used to auto-start the engine on
/// launch with the user's last-used options.
@immutable
class StoredAudioConfig {
  /// Creates a [StoredAudioConfig].
  const StoredAudioConfig({
    required this.sampleRate,
    required this.bufferFrames,
    required this.monitorInput,
    required this.mergeToMono,
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

  /// Whether captured input is monitored to the output.
  final bool monitorInput;

  /// Whether input channels are averaged to mono and fed to both outputs.
  final bool mergeToMono;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoredAudioConfig &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          monitorInput == other.monitorInput &&
          mergeToMono == other.mergeToMono;

  @override
  int get hashCode =>
      Object.hash(sampleRate, bufferFrames, monitorInput, mergeToMono);
}

/// Persists user/device settings via a [KeyValueStore].
///
/// Stores the per-device record-offset latency calibration, the last-used audio
/// device configuration (so the engine can auto-start on launch), the UI mode,
/// per-track display names, and big-picture view preferences.
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

  static const String _audioSampleRateKey = 'audio.sample_rate';
  static const String _audioBufferFramesKey = 'audio.buffer_frames';
  static const String _audioMonitorKey = 'audio.monitor_input';
  static const String _audioMergeToMonoKey = 'audio.merge_to_mono';

  /// Loads the last-used audio configuration, or `null` if none has been saved
  /// yet (a first run, so the setup flow should be shown).
  Future<StoredAudioConfig?> loadAudioConfig() async {
    final sampleRate = await _store.getInt(_audioSampleRateKey);
    final bufferFrames = await _store.getInt(_audioBufferFramesKey);
    if (sampleRate == null || bufferFrames == null) return null;
    return StoredAudioConfig(
      sampleRate: sampleRate,
      bufferFrames: bufferFrames,
      monitorInput: await _store.getBool(_audioMonitorKey) ?? true,
      mergeToMono: await _store.getBool(_audioMergeToMonoKey) ?? true,
    );
  }

  /// Saves the audio [config] so the engine can auto-start with it next launch.
  Future<void> saveAudioConfig(StoredAudioConfig config) async {
    await _store.setInt(_audioSampleRateKey, config.sampleRate);
    await _store.setInt(_audioBufferFramesKey, config.bufferFrames);
    await _store.setBool(_audioMonitorKey, value: config.monitorInput);
    await _store.setBool(_audioMergeToMonoKey, value: config.mergeToMono);
  }

  static const String _showWaveformWindowKey = 'big_picture.waveform_window';

  /// Whether the secondary output-waveform window should open in big-picture
  /// mode. Defaults to `true` when unset.
  Future<bool> loadShowWaveformWindow() async =>
      await _store.getBool(_showWaveformWindowKey) ?? true;

  /// Saves whether the secondary output-waveform window should open.
  Future<void> saveShowWaveformWindow({required bool value}) =>
      _store.setBool(_showWaveformWindowKey, value: value);

  String _trackNameKey(int channel) => 'track_name.$channel';

  /// Loads the custom display name for track [channel], or `null` if unset.
  Future<String?> loadTrackName(int channel) =>
      _store.getString(_trackNameKey(channel));

  /// Saves the custom display [name] for track [channel].
  Future<void> saveTrackName(int channel, String name) =>
      _store.setString(_trackNameKey(channel), name);
}
