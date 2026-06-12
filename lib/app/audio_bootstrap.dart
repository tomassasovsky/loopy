import 'package:flutter/foundation.dart';
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
  // Resolve the exclusive-access default here (not in storage): an unset value
  // means OS-exclusive on Windows, shared elsewhere. The engine falls back to
  // shared if exclusive is refused, so this is always safe.
  final exclusive =
      await settings.loadAudioExclusive() ??
      (defaultTargetPlatform == TargetPlatform.windows);
  final loopback = repository.detectLoopback();
  final result = repository.startEngine(
    EngineConfig(
      sampleRate: saved.sampleRate,
      bufferFrames: saved.bufferFrames,
      inputChannels: saved.inputChannels,
      outputChannels: saved.outputChannels,
      passthrough: saved.monitorInput,
      exclusive: exclusive,
      maxLoopFrames: saved.maxLoopMinutes <= 0
          ? 0
          : saved.maxLoopMinutes * 60 * saved.sampleRate,
      // An explicitly chosen input device always wins: only auto-route capture
      // to a detected loopback when no capture device was pinned (otherwise a
      // ubiquitous "monitor" source — e.g. on PipeWire — would commandeer the
      // capture path and ignore the saved interface).
      useLoopbackCapture:
          loopback.isAutoRoutable && saved.captureDeviceId.isEmpty,
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
  } else if ((loopback.isAutoRoutable && saved.captureDeviceId.isEmpty) ||
      status.excludedInputMask != 0) {
    repository.measureLatency();
  }

  // Restore per-track transport overrides and every lane's routing / mix /
  // effects so saved multi-lane setups are reapplied on launch (mirroring the
  // latency-offset restore above).
  for (final track in repository.state.tracks) {
    final quantize = await settings.loadTrackQuantize(track.channel);
    if (quantize != null) {
      repository.setTrackQuantize(channel: track.channel, enabled: quantize);
    }
    final multiple = await settings.loadTrackMultiple(track.channel);
    if (multiple > 0) {
      repository.setTrackMultiple(channel: track.channel, multiple: multiple);
    }
    // Restore the saved lane count first so the engine allocates the added
    // lanes before they are configured below.
    final laneCount = await settings.loadLaneCount(track.channel);
    if (laneCount > 1) {
      repository.setLaneCount(channel: track.channel, count: laneCount);
    }
    for (var lane = 0; lane < laneCount; lane++) {
      final inputChannel = await settings.loadLaneInput(track.channel, lane);
      if (inputChannel != null) {
        repository.setLaneInput(
          channel: track.channel,
          lane: lane,
          inputChannel: inputChannel,
        );
      }
      final outputMask = await settings.loadLaneOutput(track.channel, lane);
      if (outputMask != null) {
        repository.setLaneOutput(
          channel: track.channel,
          lane: lane,
          mask: outputMask,
        );
      }
      final volume = await settings.loadLaneVolume(track.channel, lane);
      if (volume != null) {
        repository.setLaneVolume(volume, channel: track.channel, lane: lane);
      }
      final muted = await settings.loadLaneMute(track.channel, lane);
      if (muted != null) {
        repository.setLaneMute(
          muted: muted,
          channel: track.channel,
          lane: lane,
        );
      }
      // Restore the saved ordered effect chain in one shot.
      final effects = decodeTrackEffects(
        await settings.loadLaneEffects(track.channel, lane),
      );
      if (effects.isNotEmpty) {
        repository.setLaneEffects(
          channel: track.channel,
          lane: lane,
          effects: effects,
        );
      }
    }
  }

  // Per-input live monitors are restored by MonitorCubit.load() (the shell
  // creates and loads it on every launch), so they are not re-applied here.
  return true;
}
