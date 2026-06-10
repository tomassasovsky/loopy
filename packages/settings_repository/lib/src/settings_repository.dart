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
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.maxLoopMinutes = 0,
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

  /// Whether captured input is monitored to the output.
  final bool monitorInput;

  /// Requested hardware capture channel count (`0` => device default).
  final int inputChannels;

  /// Requested hardware playback channel count (`0` => device default).
  final int outputChannels;

  /// Maximum loop length the engine allocates per track, in whole minutes.
  /// `0` defers to the engine default. Stored as minutes (not frames) so the
  /// user's intent survives a later sample-rate change.
  final int maxLoopMinutes;

  /// Pinned playback device id (empty => system default).
  final String playbackDeviceId;

  /// Pinned capture device id (empty => system default).
  final String captureDeviceId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoredAudioConfig &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          monitorInput == other.monitorInput &&
          inputChannels == other.inputChannels &&
          outputChannels == other.outputChannels &&
          maxLoopMinutes == other.maxLoopMinutes &&
          playbackDeviceId == other.playbackDeviceId &&
          captureDeviceId == other.captureDeviceId;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    bufferFrames,
    monitorInput,
    inputChannels,
    outputChannels,
    maxLoopMinutes,
    playbackDeviceId,
    captureDeviceId,
  );
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
  static const String _audioInputChannelsKey = 'audio.input_channels';
  static const String _audioOutputChannelsKey = 'audio.output_channels';
  static const String _audioMaxLoopMinutesKey = 'audio.max_loop_minutes';
  static const String _audioPlaybackDeviceIdKey = 'audio.playback_device_id';
  static const String _audioCaptureDeviceIdKey = 'audio.capture_device_id';

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
      inputChannels: await _store.getInt(_audioInputChannelsKey) ?? 0,
      outputChannels: await _store.getInt(_audioOutputChannelsKey) ?? 0,
      maxLoopMinutes: await _store.getInt(_audioMaxLoopMinutesKey) ?? 0,
      playbackDeviceId: await _store.getString(_audioPlaybackDeviceIdKey) ?? '',
      captureDeviceId: await _store.getString(_audioCaptureDeviceIdKey) ?? '',
    );
  }

  /// Saves the audio [config] so the engine can auto-start with it next launch.
  Future<void> saveAudioConfig(StoredAudioConfig config) async {
    await _store.setInt(_audioSampleRateKey, config.sampleRate);
    await _store.setInt(_audioBufferFramesKey, config.bufferFrames);
    await _store.setBool(_audioMonitorKey, value: config.monitorInput);
    await _store.setInt(_audioInputChannelsKey, config.inputChannels);
    await _store.setInt(_audioOutputChannelsKey, config.outputChannels);
    await _store.setInt(_audioMaxLoopMinutesKey, config.maxLoopMinutes);
    await _store.setString(
      _audioPlaybackDeviceIdKey,
      config.playbackDeviceId,
    );
    await _store.setString(_audioCaptureDeviceIdKey, config.captureDeviceId);
  }

  static const String _showWaveformWindowKey = 'big_picture.waveform_window';

  /// Whether the secondary output-waveform window should open in big-picture
  /// mode. Defaults to `true` when unset.
  Future<bool> loadShowWaveformWindow() async =>
      await _store.getBool(_showWaveformWindowKey) ?? true;

  /// Saves whether the secondary output-waveform window should open.
  Future<void> saveShowWaveformWindow({required bool value}) =>
      _store.setBool(_showWaveformWindowKey, value: value);

  static const String _bankEnabledKey = 'big_picture.bank_enabled';

  /// Whether the second bank of four tracks is enabled (8 tracks total, shown
  /// as two banks of four). Defaults to `true` (two banks of four).
  Future<bool> loadBankEnabled() async =>
      await _store.getBool(_bankEnabledKey) ?? true;

  /// Saves whether the second bank of four tracks is enabled.
  Future<void> saveBankEnabled({required bool value}) =>
      _store.setBool(_bankEnabledKey, value: value);

  static const String _defaultPerformanceModeKey = 'big_picture.default_mode';

  /// Loads the persisted default Big Picture performance mode (an opaque token,
  /// e.g. `'record'` / `'play'`), or `null` if unset. The presentation layer
  /// maps the token to its mode enum.
  Future<String?> loadDefaultPerformanceMode() =>
      _store.getString(_defaultPerformanceModeKey);

  /// Saves the default Big Picture performance [mode] token.
  Future<void> saveDefaultPerformanceMode(String mode) =>
      _store.setString(_defaultPerformanceModeKey, mode);

  static const String _refreshHzKey = 'ui.refresh_hz';

  /// Loads the UI snapshot-poll rate in Hz. Defaults to `60` when unset.
  Future<int> loadRefreshHz() async => await _store.getInt(_refreshHzKey) ?? 60;

  /// Saves the UI snapshot-poll rate in [hz].
  Future<void> saveRefreshHz(int hz) => _store.setInt(_refreshHzKey, hz);

  static const String _quantizeKey = 'looper.quantize';

  /// Whether recording is quantized to the loop grid. Defaults to `false`
  /// (the free-running behaviour) when unset.
  Future<bool> loadQuantize() async =>
      await _store.getBool(_quantizeKey) ?? false;

  /// Saves whether recording is quantized to the loop grid.
  Future<void> saveQuantize({required bool value}) =>
      _store.setBool(_quantizeKey, value: value);

  static const String _recDubKey = 'looper.rec_dub';

  /// Whether a record press finalizing a recording continues into overdub
  /// (rec/dub) instead of playback. Defaults to `false`.
  Future<bool> loadRecDub() async => await _store.getBool(_recDubKey) ?? false;

  /// Saves the rec/dub second-press mode.
  Future<void> saveRecDub({required bool value}) =>
      _store.setBool(_recDubKey, value: value);

  static const String _defaultMultipleKey = 'looper.default_multiple';

  /// Loads the global default loop length (`0` = auto), or `0` if unset.
  Future<int> loadDefaultMultiple() async =>
      await _store.getInt(_defaultMultipleKey) ?? 0;

  /// Saves the global default loop length (`0` = auto).
  Future<void> saveDefaultMultiple(int multiple) =>
      _store.setInt(_defaultMultipleKey, multiple);

  static const String _autoRecordKey = 'looper.auto_record';

  /// Whether recording is sound-activated (starts on input). Defaults to
  /// `false`.
  Future<bool> loadAutoRecord() async =>
      await _store.getBool(_autoRecordKey) ?? false;

  /// Saves the sound-activated recording preference.
  Future<void> saveAutoRecord({required bool value}) =>
      _store.setBool(_autoRecordKey, value: value);

  String _trackMultipleKey(int channel) => 'track_multiple.$channel';

  /// Loads track [channel]'s forced loop multiple (`0` = auto; `0` if unset).
  Future<int> loadTrackMultiple(int channel) async =>
      await _store.getInt(_trackMultipleKey(channel)) ?? 0;

  /// Saves track [channel]'s forced loop multiple (`0` = auto).
  Future<void> saveTrackMultiple(int channel, int multiple) =>
      _store.setInt(_trackMultipleKey(channel), multiple);

  static const String _monitorModeKey = 'monitor.mode';
  static const String _monitorInputMaskKey = 'monitor.input_mask';
  static const String _monitorOutputMaskKey = 'monitor.output_mask';

  /// Loads the monitor-routing mode token (`'custom'` / `'followSelected'`), or
  /// `null` if unset. The presentation layer maps it to its mode enum.
  Future<String?> loadMonitorMode() => _store.getString(_monitorModeKey);

  /// Saves the monitor-routing [mode] token.
  Future<void> saveMonitorMode(String mode) =>
      _store.setString(_monitorModeKey, mode);

  /// Loads the custom monitor input bitmask. Defaults to `0x1` (input 0).
  Future<int> loadMonitorInputMask() async =>
      await _store.getInt(_monitorInputMaskKey) ?? 0x1;

  /// Saves the custom monitor input bitmask.
  Future<void> saveMonitorInputMask(int mask) =>
      _store.setInt(_monitorInputMaskKey, mask);

  /// Loads the custom monitor output bitmask. Defaults to `0x3` (outs 0 + 1).
  Future<int> loadMonitorOutputMask() async =>
      await _store.getInt(_monitorOutputMaskKey) ?? 0x3;

  /// Saves the custom monitor output bitmask.
  Future<void> saveMonitorOutputMask(int mask) =>
      _store.setInt(_monitorOutputMaskKey, mask);

  String _trackNameKey(int channel) => 'track_name.$channel';

  /// Loads the custom display name for track [channel], or `null` if unset.
  Future<String?> loadTrackName(int channel) =>
      _store.getString(_trackNameKey(channel));

  /// Saves the custom display [name] for track [channel].
  Future<void> saveTrackName(int channel, String name) =>
      _store.setString(_trackNameKey(channel), name);

  String _trackQuantizeKey(int channel) => 'track_quantize.$channel';

  /// Loads track [channel]'s quantize override: `null` (inherit the global
  /// default), `false` (force off), or `true` (force on).
  Future<bool?> loadTrackQuantize(int channel) async {
    final value = await _store.getInt(_trackQuantizeKey(channel));
    if (value == null || value < 0) return null;
    return value > 0;
  }

  /// Saves track [channel]'s quantize override (`null` => inherit).
  Future<void> saveTrackQuantize(int channel, {required bool? enabled}) =>
      _store.setInt(
        _trackQuantizeKey(channel),
        enabled == null ? -1 : (enabled ? 1 : 0),
      );

  String _trackInputMaskKey(int channel) => 'track_input_mask.$channel';
  String _trackOutputMaskKey(int channel) => 'track_output_mask.$channel';

  /// Loads the saved record-source input bitmask for track [channel], or `null`
  /// if unset.
  Future<int?> loadTrackInputMask(int channel) =>
      _store.getInt(_trackInputMaskKey(channel));

  /// Saves the record-source input [mask] for track [channel].
  Future<void> saveTrackInputMask(int channel, int mask) =>
      _store.setInt(_trackInputMaskKey(channel), mask);

  /// Loads the saved output-routing bitmask for track [channel], or `null` if
  /// unset.
  Future<int?> loadTrackOutputMask(int channel) =>
      _store.getInt(_trackOutputMaskKey(channel));

  /// Saves the output-routing [mask] for track [channel].
  Future<void> saveTrackOutputMask(int channel, int mask) =>
      _store.setInt(_trackOutputMaskKey(channel), mask);

  /// Clears all settings.
  Future<void> clear() => _store.clear();
}
