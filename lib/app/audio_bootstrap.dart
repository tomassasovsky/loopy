import 'package:flutter/foundation.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// The platform default for OS-exclusive device access: on by default on
/// Windows (full device control via WASAPI exclusive mode), off elsewhere.
///
/// Resolved here in the presentation layer — the single source of this OS rule.
/// The cubit and repository hold no OS policy (the engine still falls back to
/// shared if exclusive is refused, so this is always safe).
bool get platformDefaultExclusive =>
    defaultTargetPlatform == TargetPlatform.windows;

/// Whether the ASIO backend is selectable on this platform: Windows only (ASIO
/// is a Windows-only API). Resolved here in the presentation layer — the single
/// source of this OS rule — and injected into the audio-setup cubit, so the
/// cubit holds no OS policy (mirroring [platformDefaultExclusive]).
bool get platformAsioSelectable =>
    defaultTargetPlatform == TargetPlatform.windows;

/// The outcome of [tryAutoStartEngine]: whether the engine came up, plus the
/// ASIO drivers enumerated at startup so the audio-setup cubit can cache them
/// for the picker (it cannot re-enumerate while ASIO holds the device — R1).
typedef AutoStartResult = ({bool started, List<AudioDevice> asioDrivers});

/// Loads the last-used audio configuration and starts the engine — from the
/// saved config when one exists, otherwise from a sensible first-run default
/// (the first ASIO driver on Windows, the system default elsewhere). The app
/// always lands on the looper; the returned `started` flag is `false` only when
/// no device could be opened (e.g. Windows with no ASIO driver), which the
/// looper surfaces as an "audio not running" affordance.
Future<AutoStartResult> tryAutoStartEngine({
  required LooperRepository repository,
  required SettingsRepository settings,
}) async {
  // Enumerate ASIO drivers once, before opening any device (R1), so the cubit
  // can cache them even after the engine auto-starts on ASIO.
  final asioDrivers = platformAsioSelectable
      ? repository.asioDrivers()
      : const <AudioDevice>[];

  final saved = await settings.loadAudioConfig();
  if (saved == null) {
    final started = await _firstRunAutoStart(
      repository: repository,
      settings: settings,
      asioDrivers: asioDrivers,
    );
    return (started: started, asioDrivers: asioDrivers);
  }
  // Resolve the exclusive-access default here (not in storage): an unset value
  // means OS-exclusive on Windows, shared elsewhere. The engine falls back to
  // shared if exclusive is refused, so this is always safe.
  final exclusive =
      await settings.loadAudioExclusive() ?? platformDefaultExclusive;
  final loopback = repository.detectLoopback();
  final result = repository.startEngine(
    EngineConfig(
      sampleRate: saved.sampleRate,
      bufferFrames: saved.bufferFrames,
      inputChannels: saved.inputChannels,
      outputChannels: saved.outputChannels,
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
      // Relaunch into the saved backend. This config assembly is duplicated
      // from the cubit's _engineConfig, so both must carry backend/asioDriver
      // or an auto-start would diverge from an interactive start. If the saved
      // ASIO driver is gone, the native dispatcher falls back to WASAPI and the
      // cubit surfaces it via engineStatus.activeBackend.
      backend: saved.backend,
      asioDriver: saved.asioDriver,
    ),
  );
  if (!result.isOk) return (started: false, asioDrivers: asioDrivers);

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
  return (started: true, asioDrivers: asioDrivers);
}

/// Starts the engine on a first run (no saved config) and persists the chosen
/// config so later launches take the normal saved path. On Windows, opens the
/// first enumerated ASIO driver (returns `false` if none is installed — the
/// looper then shows the "no audio" affordance). Elsewhere, opens the system
/// default with a zero-config [EngineConfig]. Returns whether the engine
/// started.
Future<bool> _firstRunAutoStart({
  required LooperRepository repository,
  required SettingsRepository settings,
  required List<AudioDevice> asioDrivers,
}) async {
  if (platformAsioSelectable) {
    if (asioDrivers.isEmpty) return false; // no driver: land stopped (D4/PR5).
    final driver = asioDrivers.first;
    final sampleRate = _preferred(driver.sampleRates, 48000);
    final bufferFrames = _preferred(driver.bufferSizes, 128);
    final result = repository.startEngine(
      EngineConfig(
        sampleRate: sampleRate,
        bufferFrames: bufferFrames,
        backend: AudioBackend.asio,
        asioDriver: driver.id,
      ),
    );
    if (!result.isOk) return false;
    await settings.saveAudioConfig(
      StoredAudioConfig(
        sampleRate: sampleRate,
        bufferFrames: bufferFrames,
        backend: AudioBackend.asio,
        asioDriver: driver.id,
      ),
    );
    return true;
  }

  // macOS/Linux: open the system default (zero-config), then persist the
  // negotiated rate/buffer so the next launch takes the saved-config path.
  final result = repository.startEngine(const EngineConfig());
  if (!result.isOk) return false;
  final status = repository.state.status;
  await settings.saveAudioConfig(
    StoredAudioConfig(
      sampleRate: status.sampleRate > 0 ? status.sampleRate : 48000,
      bufferFrames: status.bufferFrames > 0 ? status.bufferFrames : 128,
    ),
  );
  return true;
}

/// Returns [wanted] when [options] is empty or contains it; otherwise the first
/// option. Used to pick a first-run rate/buffer from a driver's reported set,
/// preferring the common default when the driver allows it.
int _preferred(List<int> options, int wanted) =>
    options.isEmpty || options.contains(wanted) ? wanted : options.first;
