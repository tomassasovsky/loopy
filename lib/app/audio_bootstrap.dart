import 'package:flutter/foundation.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/console_audio_devices.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:loopy/common/console_mode.dart';
import 'package:loopy/logging/app_log.dart';
// Settings owns its own AudioBackend; mapped to/from the looper domain backend
// here. Prefixed only for that enum so the unprefixed one is the domain type.
import 'package:settings_repository/settings_repository.dart' hide AudioBackend;
import 'package:settings_repository/settings_repository.dart'
    as persisted
    show AudioBackend;

/// Whether the ASIO backend is selectable on this platform: Windows only (ASIO
/// is a Windows-only API). Resolved here in the presentation layer — the single
/// source of this OS rule — and injected into the audio-setup cubit, so the
/// cubit holds no OS policy.
bool get platformAsioSelectable =>
    defaultTargetPlatform == TargetPlatform.windows;

/// The outcome of [tryAutoStartEngine]: whether the engine came up, the ASIO
/// drivers enumerated at startup so the audio-setup cubit can cache them for
/// the picker (it cannot re-enumerate while ASIO holds the device — R1), and
/// the config that was attempted when a *pinned* device could not be opened —
/// handed to the audio-recovery cubit so the engine auto-starts when that
/// device reappears (the in-repo supervisor only arms after a good start).
/// `recoveryConfig` is null when the engine started, on first run, or for the
/// system default (which is never auto-recovered).
typedef AutoStartResult = ({
  bool started,
  List<AudioDevice> asioDrivers,
  EngineConfig? recoveryConfig,
});

/// Loads the last-used audio configuration and starts the engine — from the
/// saved config when one exists, otherwise from a sensible first-run default
/// (the first ASIO driver on Windows, the system default elsewhere; on a
/// [consoleMode] build, the first non-default duplex interface when ids are
/// empty). The app always lands on the looper; the returned `started` flag is
/// `false` only when no device could be opened (e.g. Windows with no ASIO
/// driver), which the looper surfaces as an "audio not running" affordance.
///
/// [consoleMode] defaults to [kConsoleMode]; tests inject `true`/`false`
/// without a dart-define.
Future<AutoStartResult> tryAutoStartEngine({
  required LooperRepository repository,
  required SettingsRepository settings,
  bool consoleMode = kConsoleMode,
}) async {
  // Enumerate ASIO drivers once, before opening any device (R1), so the cubit
  // can cache them even after the engine auto-starts on ASIO.
  final asioDrivers = platformAsioSelectable
      ? repository.asioDrivers()
      : const <AudioDevice>[];

  final saved = await settings.loadAudioConfig();
  if (saved == null) {
    AppLog.info('audio auto-start: first run (no saved config)');
    final started = await _firstRunAutoStart(
      repository: repository,
      settings: settings,
      asioDrivers: asioDrivers,
      consoleMode: consoleMode,
    );
    AppLog.info('audio auto-start: first run started=$started');
    return (started: started, asioDrivers: asioDrivers, recoveryConfig: null);
  }
  // On Windows (ASIO-only) the engine always runs ASIO, and the driver is found
  // automatically: keep the saved one if it is still enumerated, otherwise fall
  // back to the first installed driver. This heals a config saved with the
  // miniaudio backend or a stale/empty driver (e.g. from an earlier build), so
  // the app finds the installed driver on its own — the user can still switch
  // it in settings.
  // With no driver installed at all, land stopped (the looper shows the
  // no-driver / ASIO4ALL affordance), mirroring the first-run path. The coercion
  // mirrors the cubit's hydration so the engine and the UI never disagree.
  final backend = platformAsioSelectable
      ? AudioBackend.asio
      : engineBackendOf(saved.backend);
  final asioDriver = platformAsioSelectable
      ? AudioSetupCubit.resolveAsioDriver(saved.asioDriver, asioDrivers)
      : saved.asioDriver;
  if (platformAsioSelectable && asioDriver.isEmpty) {
    AppLog.warn('audio auto-start: no ASIO driver available');
    return (started: false, asioDrivers: asioDrivers, recoveryConfig: null);
  }

  // Console heal: empty persisted ids lock every boot onto the system default.
  // When both are empty, try the same non-default duplex pick as first-run.
  var playbackId = saved.playbackDeviceId;
  var captureId = saved.captureDeviceId;
  var consolePinned = false;
  if (consoleMode &&
      !platformAsioSelectable &&
      playbackId.isEmpty &&
      captureId.isEmpty) {
    final pick = pickConsoleAudioDevices(repository.devices());
    if (pick != null) {
      playbackId = pick.playbackId;
      captureId = pick.captureId;
      consolePinned = true;
      AppLog.info(
        'audio auto-start: console empty-id heal '
        'playback=$playbackId capture=$captureId',
      );
    }
  }

  final loopback = repository.detectLoopback();
  final config = EngineConfig(
    sampleRate: saved.sampleRate,
    bufferFrames: saved.bufferFrames,
    inputChannels: saved.inputChannels,
    outputChannels: saved.outputChannels,
    maxLoopFrames: saved.maxLoopMinutes <= 0
        ? 0
        : saved.maxLoopMinutes * 60 * saved.sampleRate,
    // An explicitly chosen input device always wins: only auto-route capture
    // to a detected loopback when no capture device was pinned (otherwise a
    // ubiquitous "monitor" source — e.g. on PipeWire — would commandeer the
    // capture path and ignore the saved interface).
    useLoopbackCapture: loopback.isAutoRoutable && captureId.isEmpty,
    playbackDeviceId: playbackId,
    captureDeviceId: captureId,
    // This config assembly is duplicated from the cubit's _engineConfig, so
    // both must carry backend/asioDriver or an auto-start would diverge from
    // an interactive start.
    backend: backend,
    asioDriver: asioDriver,
  );
  AppLog.info(
    'audio auto-start: opening playback=${config.playbackDeviceId} '
    'capture=${config.captureDeviceId} rate=${config.sampleRate} '
    'buffer=${config.bufferFrames}',
  );
  var result = repository.startEngine(config);
  if (!result.isOk && consolePinned) {
    // Empty-id heal picked a duplex that would not open — fall back to the
    // system default (same as first-run) so the kiosk still comes up.
    AppLog.warn(
      'audio auto-start: console heal open failed result=${result.name}; '
      'falling back to system default',
    );
    playbackId = '';
    captureId = '';
    consolePinned = false;
    final fallback = EngineConfig(
      sampleRate: saved.sampleRate,
      bufferFrames: saved.bufferFrames,
      inputChannels: saved.inputChannels,
      outputChannels: saved.outputChannels,
      maxLoopFrames: saved.maxLoopMinutes <= 0
          ? 0
          : saved.maxLoopMinutes * 60 * saved.sampleRate,
      useLoopbackCapture: loopback.isAutoRoutable,
      backend: backend,
      asioDriver: asioDriver,
    );
    result = repository.startEngine(fallback);
    if (result.isOk) {
      // Persist empty ids so we don't retry a broken pin every boot; the next
      // heal only runs while both ids stay empty, and first-run-style pin
      // happens again once a duplex is present and openable.
      await settings.saveAudioConfig(
        StoredAudioConfig(
          sampleRate: saved.sampleRate,
          bufferFrames: saved.bufferFrames,
          inputChannels: saved.inputChannels,
          outputChannels: saved.outputChannels,
          maxLoopMinutes: saved.maxLoopMinutes,
          backend: saved.backend,
          asioDriver: saved.asioDriver,
        ),
      );
    }
  }
  if (!result.isOk) {
    AppLog.error('audio auto-start: open failed result=${result.name}');
    // A pinned device that could not be opened (e.g. the interface is
    // unplugged at boot) arms the recovery cubit to auto-start when it
    // reappears. Prefer the originally attempted pin (including a failed
    // console heal) so recovery can reopen it when the interface returns.
    final attemptedPin =
        config.playbackDeviceId.isNotEmpty || config.captureDeviceId.isNotEmpty;
    return (
      started: false,
      asioDrivers: asioDrivers,
      recoveryConfig: attemptedPin ? config : null,
    );
  }
  if (consolePinned) {
    await settings.saveAudioConfig(
      StoredAudioConfig(
        sampleRate: saved.sampleRate,
        bufferFrames: saved.bufferFrames,
        inputChannels: saved.inputChannels,
        outputChannels: saved.outputChannels,
        maxLoopMinutes: saved.maxLoopMinutes,
        playbackDeviceId: playbackId,
        captureDeviceId: captureId,
        backend: saved.backend,
        asioDriver: saved.asioDriver,
      ),
    );
  }

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
  } else if ((loopback.isAutoRoutable && captureId.isEmpty) ||
      status.excludedInputMask != 0) {
    repository.measureLatency();
  }

  // Restore the global default loop multiple (×N). Like the latency offset
  // above, RecordOptionsCubit normally applies this — but that cubit is not
  // created on the auto-start path and may not have initialized before the
  // pedal triggers a recording, so without this a saved forced ×1 reverts to
  // auto-round-up and loops record at ×2/×4.
  repository.setDefaultMultiple(multiple: await settings.loadDefaultMultiple());

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
    final lengthPreset = await settings.loadTrackLengthPreset(track.channel);
    if (lengthPreset > 0) {
      repository.setTrackLengthPreset(
        channel: track.channel,
        bars: lengthPreset,
      );
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

  // Restore the structural output gate. Only explicitly-disabled outputs were
  // persisted (default-on), so a missing key means enabled and needs no call.
  // Scans the engine-aligned ceiling [0, kMaxOutputs) — see [kMaxOutputs].
  for (var output = 0; output < kMaxOutputs; output++) {
    if (await settings.loadOutputEnabled(output) == false) {
      repository.setOutputEnabled(output: output, enabled: false);
    }
  }

  // Per-input live monitors are restored by MonitorCubit.load() (the shell
  // creates and loads it on every launch), so they are not re-applied here.
  final pinned = playbackId.isNotEmpty || captureId.isNotEmpty;
  AppLog.info('audio auto-start: started ok pinned=$pinned');
  return (started: true, asioDrivers: asioDrivers, recoveryConfig: null);
}

/// Starts the engine on a first run (no saved config) and persists the chosen
/// config so later launches take the normal saved path. On Windows, opens the
/// first enumerated ASIO driver (returns `false` if none is installed — the
/// looper then shows the "no audio" affordance). Elsewhere, opens the system
/// default — or, when [consoleMode] is on, the first non-default duplex
/// interface ([pickConsoleAudioDevices]). Returns whether the engine started.
Future<bool> _firstRunAutoStart({
  required LooperRepository repository,
  required SettingsRepository settings,
  required List<AudioDevice> asioDrivers,
  required bool consoleMode,
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
        backend: persisted.AudioBackend.asio,
        asioDriver: driver.id,
      ),
    );
    return true;
  }

  var playbackId = '';
  var captureId = '';
  if (consoleMode) {
    final pick = pickConsoleAudioDevices(repository.devices());
    if (pick != null) {
      playbackId = pick.playbackId;
      captureId = pick.captureId;
      AppLog.info(
        'audio first-run: console auto-pin '
        'playback=$playbackId capture=$captureId',
      );
    } else {
      AppLog.info(
        'audio first-run: console found no non-default duplex; '
        'using system default',
      );
    }
  }

  var result = repository.startEngine(
    EngineConfig(playbackDeviceId: playbackId, captureDeviceId: captureId),
  );
  if (!result.isOk && (playbackId.isNotEmpty || captureId.isNotEmpty)) {
    // Console pin failed (interface busy/absent) — fall back to system default
    // so the kiosk still comes up, matching pre-auto-pin first-run behavior.
    AppLog.warn(
      'audio first-run: console pin open failed result=${result.name}; '
      'falling back to system default',
    );
    playbackId = '';
    captureId = '';
    result = repository.startEngine(const EngineConfig());
  }
  if (!result.isOk) {
    AppLog.error('audio first-run: open failed result=${result.name}');
    return false;
  }
  final status = repository.state.status;
  await settings.saveAudioConfig(
    StoredAudioConfig(
      sampleRate: status.sampleRate > 0 ? status.sampleRate : 48000,
      bufferFrames: status.bufferFrames > 0 ? status.bufferFrames : 128,
      playbackDeviceId: playbackId,
      captureDeviceId: captureId,
    ),
  );
  return true;
}

/// Returns [wanted] when [options] is empty or contains it; otherwise the first
/// option. Used to pick a first-run rate/buffer from a driver's reported set,
/// preferring the common default when the driver allows it.
int _preferred(List<int> options, int wanted) =>
    options.isEmpty || options.contains(wanted) ? wanted : options.first;
