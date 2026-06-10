import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Loads the last-used audio configuration and, if present, starts the engine
/// with it. Returns `true` when a saved config existed and the engine started,
/// so the app can boot straight into the looper; `false` means a first run (no
/// saved config) or a failed start, so the setup flow should be shown.
Future<bool> tryAutoStartEngine({
  required LooperRepository repository,
  required SettingsRepository settings,
}) async {
  final saved = await settings.loadAudioConfig();
  if (saved == null) return false;
  final loopback = repository.detectLoopback();
  final result = repository.startEngine(
    EngineConfig(
      sampleRate: saved.sampleRate,
      bufferFrames: saved.bufferFrames,
      inputChannels: saved.inputChannels,
      outputChannels: saved.outputChannels,
      passthrough: saved.monitorInput,
      maxLoopFrames: saved.maxLoopMinutes <= 0
          ? 0
          : saved.maxLoopMinutes * 60 * saved.sampleRate,
      useLoopbackCapture: loopback.isAutoRoutable,
      playbackDeviceId: saved.playbackDeviceId,
      captureDeviceId: saved.captureDeviceId,
    ),
  );
  if (!result.isOk) return false;

  // Restore latency compensation. The interactive flow does this in
  // AudioSetupCubit, but the cubit is not created on the auto-start path, so
  // without this the engine would come up with no record offset (compensation
  // off) — overdubs would land late by the full hardware round-trip. Restore
  // the saved per-device offset; if there is none yet, auto-measure when the
  // capture path loops our output back — a cable-free loopback device or an
  // interface with dedicated loopback channels (matching the interactive
  // start). A freshly measured offset is persisted the next time the cubit is
  // created (or the next interactive measurement).
  final status = repository.state.status;
  final savedOffset = await settings.loadLatencyOffsetFrames(
    device: status.deviceName,
    sampleRate: status.sampleRate,
    bufferFrames: status.bufferFrames,
  );
  if (savedOffset != null && savedOffset > 0) {
    repository.setRecordOffset(savedOffset);
  } else if (loopback.isAutoRoutable || status.excludedInputMask != 0) {
    repository.measureLatency();
  }

  // Restore per-track I/O routing and quantize overrides so saved settings are
  // reapplied on launch (mirroring the latency-offset restore above).
  for (final track in repository.state.tracks) {
    final inputMask = await settings.loadTrackInputMask(track.channel);
    if (inputMask != null) {
      repository.setInputMask(channel: track.channel, mask: inputMask);
    }
    final mask = await settings.loadTrackOutputMask(track.channel);
    if (mask != null) {
      repository.setOutputMask(channel: track.channel, mask: mask);
    }
    final quantize = await settings.loadTrackQuantize(track.channel);
    if (quantize != null) {
      repository.setTrackQuantize(channel: track.channel, enabled: quantize);
    }
    final multiple = await settings.loadTrackMultiple(track.channel);
    if (multiple > 0) {
      repository.setTrackMultiple(channel: track.channel, multiple: multiple);
    }
    // Per-track effects chain: restore the saved ordered chain in one shot.
    final encoded = await settings.loadTrackEffects(track.channel);
    final effects = decodeTrackEffects(encoded);
    if (effects.isNotEmpty) {
      repository.setTrackEffects(channel: track.channel, effects: effects);
    }
  }
  return true;
}
