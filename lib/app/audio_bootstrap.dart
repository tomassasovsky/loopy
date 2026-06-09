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
      channels: 2,
      passthrough: saved.monitorInput,
      mergeToMono: saved.mergeToMono,
      useLoopbackCapture: loopback.isAutoRoutable,
    ),
  );
  if (!result.isOk) return false;

  // Restore latency compensation. The interactive flow does this in
  // AudioSetupCubit, but the cubit is not created on the auto-start path, so
  // without this the engine would come up with no record offset (compensation
  // off) — overdubs would land late by the full hardware round-trip. Restore
  // the saved per-device offset; if there is none yet, auto-measure when a
  // cable-free loopback is available (matching the interactive start).
  final status = repository.state.status;
  final savedOffset = await settings.loadLatencyOffsetFrames(
    device: status.deviceName,
    sampleRate: status.sampleRate,
    bufferFrames: status.bufferFrames,
  );
  if (savedOffset != null && savedOffset > 0) {
    repository.setRecordOffset(savedOffset);
  } else if (loopback.isAutoRoutable) {
    repository.measureLatency();
  }
  return true;
}
