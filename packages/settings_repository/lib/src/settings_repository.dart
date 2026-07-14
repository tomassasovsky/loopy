import 'package:flutter/foundation.dart';
import 'package:local_storage_client/local_storage_client.dart';

/// The persisted device-backend intent. A settings-layer domain enum (mirroring
/// the engine's backend) kept here so this repository holds no data-layer
/// dependency; the presentation layer maps it to/from the engine backend.
enum AudioBackend {
  /// The platform's default miniaudio backend.
  miniaudio,

  /// Windows ASIO.
  asio,
}

/// A persisted audio device configuration, used to auto-start the engine on
/// launch with the user's last-used options.
@immutable
class StoredAudioConfig {
  /// Creates a [StoredAudioConfig].
  const StoredAudioConfig({
    required this.sampleRate,
    required this.bufferFrames,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.maxLoopMinutes = 0,
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
    this.backend = AudioBackend.miniaudio,
    this.asioDriver = '',
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

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

  /// The persisted device-backend intent. Defaults to [AudioBackend.miniaudio].
  /// ASIO availability is a presentation-layer decision (Windows + an installed
  /// driver), so the repository stays platform-agnostic and holds only intent.
  final AudioBackend backend;

  /// The selected ASIO driver name (used only when [backend] is
  /// [AudioBackend.asio]). Empty on the default path.
  final String asioDriver;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoredAudioConfig &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          inputChannels == other.inputChannels &&
          outputChannels == other.outputChannels &&
          maxLoopMinutes == other.maxLoopMinutes &&
          playbackDeviceId == other.playbackDeviceId &&
          captureDeviceId == other.captureDeviceId &&
          backend == other.backend &&
          asioDriver == other.asioDriver;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    maxLoopMinutes,
    playbackDeviceId,
    captureDeviceId,
    backend,
    asioDriver,
  );
}

/// Persists user/device settings via a [KeyValueStore].
///
/// Stores the per-device record-offset latency calibration, the last-used audio
/// device configuration (so the engine can auto-start on launch), per-track
/// display names, and big-picture view preferences.
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

  static const String _audioSampleRateKey = 'audio.sample_rate';
  static const String _audioBufferFramesKey = 'audio.buffer_frames';
  // Legacy global input-monitor flag. No longer part of [StoredAudioConfig]:
  // monitoring is now the per-input routing graph (the `monitor_input.N` keys).
  // Read only by the one-time monitor migration via [loadLegacyMonitorInput].
  static const String _audioMonitorKey = 'audio.monitor_input';
  static const String _audioInputChannelsKey = 'audio.input_channels';
  static const String _audioOutputChannelsKey = 'audio.output_channels';
  static const String _audioMaxLoopMinutesKey = 'audio.max_loop_minutes';
  static const String _audioPlaybackDeviceIdKey = 'audio.playback_device_id';
  static const String _audioCaptureDeviceIdKey = 'audio.capture_device_id';
  static const String _audioBackendKey = 'audio.backend';
  static const String _audioAsioDriverKey = 'audio.asioDriver';

  /// Loads the last-used audio configuration, or `null` if none has been saved
  /// yet (a first run, so the setup flow should be shown).
  Future<StoredAudioConfig?> loadAudioConfig() async {
    final sampleRate = await _store.getInt(_audioSampleRateKey);
    final bufferFrames = await _store.getInt(_audioBufferFramesKey);
    if (sampleRate == null || bufferFrames == null) return null;
    return StoredAudioConfig(
      sampleRate: sampleRate,
      bufferFrames: bufferFrames,
      inputChannels: await _store.getInt(_audioInputChannelsKey) ?? 0,
      outputChannels: await _store.getInt(_audioOutputChannelsKey) ?? 0,
      maxLoopMinutes: await _store.getInt(_audioMaxLoopMinutesKey) ?? 0,
      playbackDeviceId: await _store.getString(_audioPlaybackDeviceIdKey) ?? '',
      captureDeviceId: await _store.getString(_audioCaptureDeviceIdKey) ?? '',
      backend: _backendFromName(await _store.getString(_audioBackendKey)),
      asioDriver: await _store.getString(_audioAsioDriverKey) ?? '',
    );
  }

  /// Resolves a stored backend name to an [AudioBackend], forward-compatibly:
  /// an unknown name (e.g. a value written by a newer build) resolves to
  /// [AudioBackend.miniaudio] rather than throwing (a defensive read).
  AudioBackend _backendFromName(String? name) =>
      AudioBackend.values.asNameMap()[name] ?? AudioBackend.miniaudio;

  /// Loads the legacy global input-monitor flag, or `null` if it was never set.
  /// Only the one-time monitor migration reads this — the live app no longer
  /// persists it (monitoring is the per-input routing graph). Nullable so the
  /// migration can tell "never configured" apart from an explicit choice.
  Future<bool?> loadLegacyMonitorInput() => _store.getBool(_audioMonitorKey);

  static const String _monitorMigratedV1Key = 'monitor.migrated_v1';

  /// Whether the one-time legacy-monitor migration has already run. Defaults to
  /// `false` so a fresh install runs (and no-ops) it once.
  Future<bool> loadMonitorMigratedV1() async =>
      await _store.getBool(_monitorMigratedV1Key) ?? false;

  /// Marks the one-time legacy-monitor migration done so it never re-runs.
  Future<void> saveMonitorMigratedV1() =>
      _store.setBool(_monitorMigratedV1Key, value: true);

  static const String _monitorMigratedV2Key = 'monitor.migrated_v2';

  /// Whether the one-time single-route → multi-lane monitor migration (v2) has
  /// already run. Defaults to `false` so a fresh install runs (and no-ops) it
  /// once. Runs after v1 (the global → per-input step) so a cold upgrade folds
  /// both in order.
  Future<bool> loadMonitorMigratedV2() async =>
      await _store.getBool(_monitorMigratedV2Key) ?? false;

  /// Marks the v2 monitor-lane migration done so it never re-runs.
  Future<void> saveMonitorMigratedV2() =>
      _store.setBool(_monitorMigratedV2Key, value: true);

  static const String _monitorMigratedV3Key = 'monitor.migrated_v3';

  /// Whether the one-time multi-lane → single-chain monitor fold (v3) has
  /// already run. Defaults to `false` so a fresh install runs (and no-ops) it
  /// once. Runs after v2 so a cold v1→v2→v3 upgrade folds in order.
  Future<bool> loadMonitorMigratedV3() async =>
      await _store.getBool(_monitorMigratedV3Key) ?? false;

  /// Marks the v3 single-chain monitor fold done so it never re-runs.
  Future<void> saveMonitorMigratedV3() =>
      _store.setBool(_monitorMigratedV3Key, value: true);

  /// Saves the audio [config] so the engine can auto-start with it next launch.
  Future<void> saveAudioConfig(StoredAudioConfig config) async {
    await _store.setInt(_audioSampleRateKey, config.sampleRate);
    await _store.setInt(_audioBufferFramesKey, config.bufferFrames);
    await _store.setInt(_audioInputChannelsKey, config.inputChannels);
    await _store.setInt(_audioOutputChannelsKey, config.outputChannels);
    await _store.setInt(_audioMaxLoopMinutesKey, config.maxLoopMinutes);
    await _store.setString(
      _audioPlaybackDeviceIdKey,
      config.playbackDeviceId,
    );
    await _store.setString(_audioCaptureDeviceIdKey, config.captureDeviceId);
    await _store.setString(_audioBackendKey, config.backend.name);
    await _store.setString(_audioAsioDriverKey, config.asioDriver);
  }

  static const String _midiInputDeviceIdKey = 'midi.input_device_id';
  static const String _midiInputDeviceNameKey = 'midi.input_device_name';

  /// Loads the pinned MIDI input device as `(id, name)`, or `null` when none
  /// has been selected (a fresh install, or after picking "None"). The `id` is
  /// the per-OS stable token used to re-open the device on launch; `name` is
  /// the human-readable label kept so a "last device not found" status can name
  /// it even while the device is absent. Additive flat keys, like `audio.*`.
  Future<({String id, String name})?> loadMidiDevice() async {
    final id = await _store.getString(_midiInputDeviceIdKey);
    if (id == null || id.isEmpty) return null;
    final name = await _store.getString(_midiInputDeviceNameKey) ?? '';
    return (id: id, name: name);
  }

  /// Pins the MIDI input device [id]/[name] so it auto-reconnects next launch.
  Future<void> saveMidiDevice({
    required String id,
    required String name,
  }) async {
    await _store.setString(_midiInputDeviceIdKey, id);
    await _store.setString(_midiInputDeviceNameKey, name);
  }

  /// Clears the pinned MIDI input device (the "None" selection), so the looper
  /// relaunches with no MIDI device attached.
  Future<void> clearMidiDevice() async {
    await _store.remove(_midiInputDeviceIdKey);
    await _store.remove(_midiInputDeviceNameKey);
  }

  static const String _pedalOutputDeviceIdKey = 'pedal.output_device_id';
  static const String _pedalOutputDeviceNameKey = 'pedal.output_device_name';

  /// Loads the pinned pedal MIDI *output* device as `(id, name)`, or `null`
  /// when none has been selected. The pedal binds one output for its LED
  /// state frames; this is the output counterpart of [loadMidiDevice] and pins
  /// it so it auto-binds next launch. Additive flat keys, like `midi.*`.
  Future<({String id, String name})?> loadPedalOutputDevice() async {
    final id = await _store.getString(_pedalOutputDeviceIdKey);
    if (id == null || id.isEmpty) return null;
    final name = await _store.getString(_pedalOutputDeviceNameKey) ?? '';
    return (id: id, name: name);
  }

  /// Pins the pedal output device [id]/[name] so it auto-binds next launch.
  Future<void> savePedalOutputDevice({
    required String id,
    required String name,
  }) async {
    await _store.setString(_pedalOutputDeviceIdKey, id);
    await _store.setString(_pedalOutputDeviceNameKey, name);
  }

  /// Clears the pinned pedal output device (the "None" selection).
  Future<void> clearPedalOutputDevice() async {
    await _store.remove(_pedalOutputDeviceIdKey);
    await _store.remove(_pedalOutputDeviceNameKey);
  }

  static const String _pedalLongPressMsKey = 'pedal.long_press_ms';

  /// Loads the pedal long-press threshold in milliseconds (Undo long-press =
  /// redo). Defaults to `500` when unset.
  Future<int> loadPedalLongPressMs() async =>
      await _store.getInt(_pedalLongPressMsKey) ?? 500;

  /// Saves the pedal long-press threshold in milliseconds.
  Future<void> savePedalLongPressMs(int ms) =>
      _store.setInt(_pedalLongPressMsKey, ms);

  static const String _pedalClearFadeMsKey = 'pedal.clear_fade_ms';

  /// Loads the pedal clear-all fade/guard window in milliseconds (`0` disables
  /// the guard — Clear erases immediately). Defaults to `1000` when unset.
  Future<int> loadPedalClearFadeMs() async =>
      await _store.getInt(_pedalClearFadeMsKey) ?? 1000;

  /// Saves the pedal clear-all fade/guard window in milliseconds.
  Future<void> savePedalClearFadeMs(int ms) =>
      _store.setInt(_pedalClearFadeMsKey, ms);

  static const String _showWaveformWindowKey = 'ui.waveform_window';

  /// Whether the secondary output-waveform window should open. Defaults to
  /// `true` when unset.
  Future<bool> loadShowWaveformWindow() async =>
      await _store.getBool(_showWaveformWindowKey) ?? true;

  /// Saves whether the secondary output-waveform window should open.
  Future<void> saveShowWaveformWindow({required bool value}) =>
      _store.setBool(_showWaveformWindowKey, value: value);

  static const String _highContrastKey = 'ui.high_contrast';

  /// Whether the manual high-contrast theme override is on. Defaults to
  /// `false`. Desktop platforms (macOS / Windows / Linux) do not deliver the OS
  /// high-contrast flag to Flutter, so this toggle is the only way to enable
  /// the high-contrast palette there.
  Future<bool> loadHighContrast() async =>
      await _store.getBool(_highContrastKey) ?? false;

  /// Saves the high-contrast override.
  Future<void> saveHighContrast({required bool value}) =>
      _store.setBool(_highContrastKey, value: value);

  static const String _showTrackIndicatorsKey = 'tracks.indicators';

  /// Whether per-track status indicators show on the Tracks-view tiles.
  /// Defaults to `true` when unset.
  Future<bool> loadShowTrackIndicators() async =>
      await _store.getBool(_showTrackIndicatorsKey) ?? true;

  /// Saves whether per-track status indicators show on the Tracks-view tiles.
  Future<void> saveShowTrackIndicators({required bool value}) =>
      _store.setBool(_showTrackIndicatorsKey, value: value);

  static const String _defaultLooperModeKey = 'looper.default_mode';

  /// Loads the persisted default looper mode (an opaque token, e.g.
  /// `'record'` / `'play'`), or `null` if unset. The presentation layer maps
  /// the token to its mode enum.
  Future<String?> loadDefaultLooperMode() =>
      _store.getString(_defaultLooperModeKey);

  /// Saves the default looper [mode] token.
  Future<void> saveDefaultLooperMode(String mode) =>
      _store.setString(_defaultLooperModeKey, mode);

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

  // Legacy single-route monitor keys (one route per input). No longer written
  // by the live app; read once by the v2 lane migration and then cleared. The
  // v1 courtesy migration still writes monitor_input.N (global flag →
  // per-input) before v2 converts it to lanes.
  String _monitorInputKey(int input) => 'monitor_input.$input';
  String _monitorInputDryKey(int input) => 'monitor_input_dry.$input';
  String _monitorInputVolKey(int input) => 'monitor_input_vol.$input';
  String _monitorInputFxKey(int input) => 'monitor_input_fx.$input';

  // Per-input single-chain monitor keys (the model the live app uses after the
  // v3 fold). The enable flag is shared with the prior model.
  String _monitorInputEnabledKey(int input) => 'monitor_input_enabled.$input';
  String _monitorOutKey(int input) => 'monitor_out.$input';
  String _monitorVolKey(int input) => 'monitor_vol.$input';
  String _monitorMuteKey(int input) => 'monitor_mute.$input';
  String _monitorFxKey(int input) => 'monitor_fx.$input';

  // Per-(input, lane) monitor keys — the prior multi-lane model. No longer
  // written by the live app; read once by the v3 single-chain fold and then
  // cleared.
  String _monitorLaneCountKey(int input) => 'monitor_lane_count.$input';
  String _monitorLaneOutKey(int input, int lane) =>
      'monitor_lane_out.$input.$lane';
  String _monitorLaneVolKey(int input, int lane) =>
      'monitor_lane_vol.$input.$lane';
  String _monitorLaneMuteKey(int input, int lane) =>
      'monitor_lane_mute.$input.$lane';
  String _monitorLaneFxKey(int input, int lane) =>
      'monitor_lane_fx.$input.$lane';

  // Structural output gate. Absence of a key means ENABLED (default-on); only
  // explicitly-disabled outputs are written, so no fixed bound is needed and
  // the set is self-cleaning when devices change.
  String _outputEnabledKey(int output) => 'output_enabled.$output';

  /// Loads hardware [input]'s LEGACY single-route monitor routing as
  /// `(enabled, outputMask)`, or `null` if it was never saved. Read only by the
  /// v1 courtesy migration and the v2 lane migration; the live app reads the
  /// per-(input, lane) keys.
  ///
  /// Packed into one int: a negative value means disabled; a non-negative value
  /// is the output bitmask of an enabled monitor.
  Future<(bool enabled, int outputMask)?> loadMonitorInput(int input) async {
    final value = await _store.getInt(_monitorInputKey(input));
    if (value == null) return null;
    return value < 0 ? (false, 0x3) : (true, value);
  }

  /// Saves hardware [input]'s legacy single-route monitor routing. Written only
  /// by the v1 courtesy migration (global flag → per-input); the v2 migration
  /// then converts it to lanes.
  Future<void> saveMonitorInput(
    int input, {
    required bool enabled,
    required int outputMask,
  }) => _store.setInt(_monitorInputKey(input), enabled ? outputMask : -1);

  /// Loads hardware [input]'s legacy monitor dry-send output bitmask
  /// (`0` = off). Read only by the v2 lane migration.
  Future<int> loadMonitorInputDry(int input) async =>
      await _store.getInt(_monitorInputDryKey(input)) ?? 0;

  /// Loads hardware [input]'s legacy monitor output gain (`0..LE_MAX_GAIN`,
  /// 2.0, +6.02 dB headroom above unity), or `null` if it was never saved.
  /// Read only by the v2 lane migration.
  Future<double?> loadMonitorInputVolume(int input) =>
      _store.getDouble(_monitorInputVolKey(input));

  /// Loads hardware [input]'s legacy monitor effect chain as an opaque encoded
  /// string (see `encodeTrackEffects`), or `null`. Read only by the v2 lane
  /// migration.
  Future<String?> loadMonitorInputEffects(int input) =>
      _store.getString(_monitorInputFxKey(input));

  /// Clears hardware [input]'s legacy single-route monitor keys once the v2
  /// lane migration has converted them to lane keys.
  Future<void> clearLegacyMonitorInput(int input) async {
    await _store.remove(_monitorInputKey(input));
    await _store.remove(_monitorInputDryKey(input));
    await _store.remove(_monitorInputVolKey(input));
    await _store.remove(_monitorInputFxKey(input));
  }

  /// Loads hardware [input]'s monitor enable flag, or `null` if never saved.
  Future<bool?> loadMonitorInputEnabled(int input) =>
      _store.getBool(_monitorInputEnabledKey(input));

  /// Saves hardware [input]'s monitor enable flag (the input-level gate).
  Future<void> saveMonitorInputEnabled(int input, {required bool enabled}) =>
      _store.setBool(_monitorInputEnabledKey(input), value: enabled);

  // ---- single-chain monitor (the live model after the v3 fold) ----

  /// Loads hardware [input]'s monitor output bitmask, or `null` if never saved
  /// (the caller defaults to full stereo `0x3`).
  Future<int?> loadMonitorOutput(int input) =>
      _store.getInt(_monitorOutKey(input));

  /// Saves hardware [input]'s monitor output bitmask.
  Future<void> saveMonitorOutput(int input, int mask) =>
      _store.setInt(_monitorOutKey(input), mask);

  /// Loads hardware [input]'s monitor output gain (`0..LE_MAX_GAIN`, 2.0,
  /// +6.02 dB headroom above unity), or `null` if never saved (the caller
  /// defaults to unity `1.0`).
  Future<double?> loadMonitorVolume(int input) =>
      _store.getDouble(_monitorVolKey(input));

  /// Saves hardware [input]'s monitor output gain (`0..LE_MAX_GAIN`, 2.0,
  /// +6.02 dB headroom above unity).
  Future<void> saveMonitorVolume(int input, double volume) =>
      _store.setDouble(_monitorVolKey(input), volume);

  /// Loads hardware [input]'s monitor mute flag, or `null` if never saved.
  Future<bool?> loadMonitorMute(int input) =>
      _store.getBool(_monitorMuteKey(input));

  /// Saves hardware [input]'s monitor mute flag.
  Future<void> saveMonitorMute(int input, {required bool muted}) =>
      _store.setBool(_monitorMuteKey(input), value: muted);

  /// Loads hardware [input]'s monitor effect chain as an opaque encoded string
  /// (see `encodeTrackEffects`), or `null` if none is saved.
  Future<String?> loadMonitorEffects(int input) =>
      _store.getString(_monitorFxKey(input));

  /// Saves hardware [input]'s [encoded] monitor effect chain.
  Future<void> saveMonitorEffects(int input, String encoded) =>
      _store.setString(_monitorFxKey(input), encoded);

  // ---- structural output gate ----

  /// Loads hardware [output]'s gate flag. `null` means the key was never
  /// written, which (default-on) the caller reads as ENABLED; `false` is the
  /// only value ever stored (an explicitly-disabled output).
  Future<bool?> loadOutputEnabled(int output) =>
      _store.getBool(_outputEnabledKey(output));

  /// Persists hardware [output]'s gate. Default-on: an enabled output REMOVES
  /// the key (so absence == enabled and the set self-cleans); a disabled output
  /// writes `false`.
  Future<void> saveOutputEnabled(int output, {required bool enabled}) async {
    if (enabled) {
      await _store.remove(_outputEnabledKey(output));
    } else {
      await _store.setBool(_outputEnabledKey(output), value: false);
    }
  }

  // ---- prior multi-lane monitor keys ----
  //
  // Written only by the v2 single-route → lanes migration (a cold-upgrade
  // stepping stone) and read once by the v3 single-chain fold, which then
  // clears them. The live app never touches these.

  /// Loads hardware [input]'s prior active monitor lane count, or `null`.
  Future<int?> loadMonitorLaneCount(int input) =>
      _store.getInt(_monitorLaneCountKey(input));

  /// Saves hardware [input]'s prior active monitor lane count (v2 migration).
  Future<void> saveMonitorLaneCount(int input, int count) =>
      _store.setInt(_monitorLaneCountKey(input), count);

  /// Loads monitor [input]'s prior lane [lane] output bitmask, or `null`.
  Future<int?> loadMonitorLaneOutput(int input, int lane) =>
      _store.getInt(_monitorLaneOutKey(input, lane));

  /// Saves monitor [input]'s prior lane [lane] output bitmask (v2 migration).
  Future<void> saveMonitorLaneOutput(int input, int lane, int mask) =>
      _store.setInt(_monitorLaneOutKey(input, lane), mask);

  /// Loads monitor [input]'s prior lane [lane] output gain, or `null`.
  Future<double?> loadMonitorLaneVolume(int input, int lane) =>
      _store.getDouble(_monitorLaneVolKey(input, lane));

  /// Saves monitor [input]'s prior lane [lane] output gain (v2 migration).
  Future<void> saveMonitorLaneVolume(int input, int lane, double volume) =>
      _store.setDouble(_monitorLaneVolKey(input, lane), volume);

  /// Loads monitor [input]'s prior lane [lane] mute flag, or `null`.
  Future<bool?> loadMonitorLaneMute(int input, int lane) =>
      _store.getBool(_monitorLaneMuteKey(input, lane));

  /// Loads monitor [input]'s prior lane [lane] effect chain (encoded), or
  /// `null`.
  Future<String?> loadMonitorLaneEffects(int input, int lane) =>
      _store.getString(_monitorLaneFxKey(input, lane));

  /// Saves monitor [input]'s lane [lane] [encoded] effect chain (v2 migration).
  Future<void> saveMonitorLaneEffects(int input, int lane, String encoded) =>
      _store.setString(_monitorLaneFxKey(input, lane), encoded);

  /// Clears hardware [input]'s prior multi-lane monitor keys for lanes
  /// `[0, laneCount)` (count + per-lane out/vol/mute/fx) once the v3 fold has
  /// converted them, so a later restore cannot resurrect multi-lane state.
  Future<void> clearMonitorLaneKeys(int input, int laneCount) async {
    await _store.remove(_monitorLaneCountKey(input));
    for (var lane = 0; lane < laneCount; lane++) {
      await _store.remove(_monitorLaneOutKey(input, lane));
      await _store.remove(_monitorLaneVolKey(input, lane));
      await _store.remove(_monitorLaneMuteKey(input, lane));
      await _store.remove(_monitorLaneFxKey(input, lane));
    }
  }

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

  String _laneCountKey(int channel) => 'lane_count.$channel';
  String _laneInputKey(int channel, int lane) => 'lane_input.$channel.$lane';
  String _laneOutputKey(int channel, int lane) => 'lane_output.$channel.$lane';
  String _laneVolKey(int channel, int lane) => 'lane_vol.$channel.$lane';
  String _laneMuteKey(int channel, int lane) => 'lane_mute.$channel.$lane';
  String _laneEffectsKey(int channel, int lane) =>
      'lane_effects.$channel.$lane';

  /// Loads track [channel]'s saved active lane count, or `1` if unset.
  Future<int> loadLaneCount(int channel) async =>
      await _store.getInt(_laneCountKey(channel)) ?? 1;

  /// Saves track [channel]'s active lane [count].
  Future<void> saveLaneCount(int channel, int count) =>
      _store.setInt(_laneCountKey(channel), count);

  /// Loads lane [lane] of track [channel]'s recorded input channel (`-1` =
  /// none), or `null` if unset.
  Future<int?> loadLaneInput(int channel, int lane) =>
      _store.getInt(_laneInputKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s recorded [inputChannel].
  Future<void> saveLaneInput(int channel, int lane, int inputChannel) =>
      _store.setInt(_laneInputKey(channel, lane), inputChannel);

  /// Loads lane [lane] of track [channel]'s output bitmask, or `null` if unset.
  Future<int?> loadLaneOutput(int channel, int lane) =>
      _store.getInt(_laneOutputKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s output [mask].
  Future<void> saveLaneOutput(int channel, int lane, int mask) =>
      _store.setInt(_laneOutputKey(channel, lane), mask);

  /// Loads lane [lane] of track [channel]'s playback volume, or `null` if
  /// unset.
  Future<double?> loadLaneVolume(int channel, int lane) =>
      _store.getDouble(_laneVolKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s playback [volume].
  Future<void> saveLaneVolume(int channel, int lane, double volume) =>
      _store.setDouble(_laneVolKey(channel, lane), volume);

  /// Loads lane [lane] of track [channel]'s mute state, or `null` if unset.
  Future<bool?> loadLaneMute(int channel, int lane) =>
      _store.getBool(_laneMuteKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s [muted] state.
  Future<void> saveLaneMute(int channel, int lane, {required bool muted}) =>
      _store.setBool(_laneMuteKey(channel, lane), value: muted);

  /// Loads lane [lane] of track [channel]'s persisted effect chain as an opaque
  /// encoded string (see `encodeTrackEffects`), or `null` if none is saved.
  Future<String?> loadLaneEffects(int channel, int lane) =>
      _store.getString(_laneEffectsKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s [encoded] effect chain.
  Future<void> saveLaneEffects(int channel, int lane, String encoded) =>
      _store.setString(_laneEffectsKey(channel, lane), encoded);

  /// Clears all settings.
  Future<void> clear() => _store.clear();
}
