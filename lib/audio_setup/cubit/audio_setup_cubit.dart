import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'audio_setup_state.dart';

/// Manages audio device options (backend, device, sample rate, buffer size).
/// Persisting a change reopens the device (or starts a stopped/failed engine
/// when the config is startable — there is no manual Start/Stop), and the cubit
/// surfaces live engine status and latency measurements.
class AudioSetupCubit extends Cubit<AudioSetupState> {
  /// Creates an [AudioSetupCubit] backed by [repository], persisting per-device
  /// latency calibration through [settings].
  AudioSetupCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
    bool asioSelectable = false,
    List<AudioDevice> initialAsioDrivers = const [],
  }) : _repository = repository,
       _settings = settings,
       _asioSelectable = asioSelectable,
       super(const AudioSetupState()) {
    _subscription = _repository.looperState.listen(_onLooperState);

    // The ASIO driver list is enumerated once at process start (before the
    // engine auto-starts) and injected here, so the picker stays populated even
    // when ASIO is already live (re-probing would tear the stream down — R1).
    final drivers = _loadAsioDrivers(
      _repository.state.status,
      cached: initialAsioDrivers,
    );

    // Hydrate from the repository immediately — [looperState] is a broadcast
    // stream that does not replay, so a new cubit would otherwise show defaults
    // until the next engine tick even when the device is already open.
    var initial = _projectFromRepository(
      _repository.state,
      current: state.copyWith(
        loopback: _repository.detectLoopback(),
        devices: _repository.devices(),
        asioDrivers: drivers,
        // Prefer the startup enumeration; when none was injected (non-Windows
        // or a test/interactive build) the freshly probed list is the cache.
        cachedAsioDrivers: initialAsioDrivers.isNotEmpty
            ? initialAsioDrivers
            : drivers,
        // Windows runs ASIO exclusively: the UI hides the backend selector /
        // pickers and the backend is coerced to ASIO on hydrate.
        asioOnly: _asioSelectable,
      ),
      hydrateConfig: true,
    );
    // On Windows the resolved driver may offer a different rate/buffer set than
    // the generic defaults, so snap the selection into it (mirrors a driver
    // switch) — otherwise the chips would show no selection.
    if (initial.asioOnly) initial = _snapRateAndBuffer(initial);
    emit(initial);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  late final StreamSubscription<LooperState> _subscription;

  /// Whether the ASIO backend is selectable on this platform (Windows only),
  /// injected by the presentation layer (`platformAsioSelectable`) so the cubit
  /// holds no OS policy and stays free of Flutter imports. ASIO is offered when
  /// is true and at least one driver enumerated.
  final bool _asioSelectable;

  /// Enumerates the installed ASIO drivers for the backend selector, honoring
  /// the R1 re-entrancy contract: the ASIO host SDK loads one process-global
  /// driver, so we never probe while a device is already running on ASIO (that
  /// would tear down the live stream). While ASIO is live we fall back to the
  /// [cached] list (enumerated at startup) instead of returning `[]`, so the
  /// picker stays populated. Returns `[]` off Windows.
  List<AudioDevice> _loadAsioDrivers(
    EngineStatus status, {
    List<AudioDevice> cached = const [],
  }) {
    if (!_asioSelectable) return const [];
    if (status.activeBackend == AudioBackend.asio) return cached;
    return _repository.asioDrivers();
  }

  /// The device profile we've loaded a saved offset for, to load only once.
  String? _hydratedDeviceKey;

  /// The last record-offset value we persisted, to avoid redundant writes.
  int? _persistedOffset;

  /// Previous pinned-device presence, to detect lost/restored transitions; and
  /// the last device name seen while present, so a disconnect banner can name
  /// the device even after the snapshot stops reporting it.
  bool? _lastDevicePresent;
  String _lastPresentDeviceName = '';

  /// Selects the requested sample rate. Persists it and, when the engine is
  /// already running, reopens the device so the change takes effect now.
  void setSampleRate(int sampleRate) {
    if (sampleRate == state.sampleRate) return;
    emit(state.copyWith(sampleRate: sampleRate));
    _persistAndApply();
  }

  /// Selects the requested buffer size. Persists it and, when the engine is
  /// already running, reopens the device so the change takes effect now (on
  /// Linux/JACK this maps to the PipeWire quantum, i.e. live latency).
  void setBufferFrames(int bufferFrames) {
    if (bufferFrames == state.bufferFrames) return;
    emit(state.copyWith(bufferFrames: bufferFrames));
    _persistAndApply();
  }

  /// Selects the device [backend] (macOS/Linux only — Windows is ASIO-only and
  /// ignores this). Switching to ASIO defaults the driver to the first
  /// enumerated one when none is chosen yet; the miniaudio device ids are kept
  /// dormant (restored on a switch back). Persists the intent and, when
  /// running, reopens the device so the change takes effect now.
  void setBackend(AudioBackend backend) {
    if (state.asioOnly || backend == state.backend) return;
    final driver =
        backend == AudioBackend.asio &&
            state.asioDriver.isEmpty &&
            state.asioDrivers.isNotEmpty
        ? state.asioDrivers.first.id
        : state.asioDriver;
    emit(
      _snapRateAndBuffer(
        state.copyWith(backend: backend, asioDriver: driver),
      ),
    );
    _persistAndApply();
  }

  /// Selects the ASIO driver to open (an id from `state.asioDrivers`). Persists
  /// the choice and, when running, reopens the device on it now.
  void setAsioDriver(String driverId) {
    if (driverId == state.asioDriver) return;
    emit(_snapRateAndBuffer(state.copyWith(asioDriver: driverId)));
    _persistAndApply();
  }

  /// Clamps the requested sample rate / buffer size into the offered options for
  /// [next] (a driver's real ASIO set, or the generic list). So switching to a
  /// backend/driver that doesn't allow the current value lands on a valid one
  /// rather than leaving no chip selected. The choice lists are never empty
  /// (they fall back to the static lists), so `.first` is safe.
  AudioSetupState _snapRateAndBuffer(AudioSetupState next) {
    final rates = next.sampleRateChoices;
    final buffers = next.bufferChoices;
    return next.copyWith(
      sampleRate: rates.contains(next.sampleRate)
          ? next.sampleRate
          : rates.first,
      bufferFrames: buffers.contains(next.bufferFrames)
          ? next.bufferFrames
          : buffers.first,
    );
  }

  /// Sets the maximum per-track loop length in whole [minutes] (`0` = engine
  /// default). Persists the choice and, when running, reopens the device so the
  /// engine reallocates buffers at the new cap.
  void setMaxLoopMinutes(int minutes) {
    if (minutes == state.maxLoopMinutes) return;
    emit(state.copyWith(maxLoopMinutes: minutes));
    _persistAndApply();
  }

  /// Selects the playback device to open (empty id = system default). Persists
  /// the choice and, when the engine is already running, reopens on it now.
  void setPlaybackDevice(String deviceId) =>
      _selectDevice(playbackDeviceId: deviceId);

  /// Selects the capture device to open (empty id = system default).
  void setCaptureDevice(String deviceId) =>
      _selectDevice(captureDeviceId: deviceId);

  void _selectDevice({String? playbackDeviceId, String? captureDeviceId}) {
    assert(
      (playbackDeviceId != null) ^ (captureDeviceId != null),
      'Either playbackDeviceId or captureDeviceId must be provided, '
      'but not both',
    );

    if (playbackDeviceId == state.playbackDeviceId ||
        captureDeviceId == state.captureDeviceId) {
      return;
    }

    emit(
      state.copyWith(
        playbackDeviceId: playbackDeviceId,
        captureDeviceId: captureDeviceId,
      ),
    );
    _persistAndApply();
  }

  /// Persists the current options and (re)starts the engine whenever the config
  /// is startable — from any status, not only while running. With no manual
  /// Start/Stop, this is the sole recovery path: changing a setting from a
  /// stopped/error state boots the engine. A reopen stops the current device
  /// first. An incomplete (non-startable) config is persisted but never boots
  /// audio. On a failed open, sets the error status (surfaced by the banner).
  void _persistAndApply() {
    unawaited(_settings.saveAudioConfig(_storedConfig()));
    if (!_isStartable) return;
    if (state.status == AudioSetupStatus.running) {
      _repository.stopEngine();
    }
    final result = _repository.startEngine(_engineConfig());
    if (result.isOk) {
      // Clear any prior error: a successful (re)start recovers from a failed
      // open, so a stale banner must not linger.
      emit(state.copyWith(status: AudioSetupStatus.running, clearError: true));
      _autoMeasureIfLoopback();
    } else {
      emit(
        state.copyWith(
          status: AudioSetupStatus.error,
          error: AudioSetupError.openDeviceFailed,
          errorDetail: result.name,
        ),
      );
    }
  }

  /// Whether the current options form a config the engine can actually open.
  /// "Startable" = a positive sample rate and buffer **and** a resolvable
  /// device: under ASIO, the selected driver must be present in the enumerated
  /// list; otherwise an empty device id is the valid system default. Persisting
  /// an incomplete config (e.g. ASIO selected with no driver) must not boot
  /// audio.
  bool get _isStartable {
    if (state.sampleRate <= 0 || state.bufferFrames <= 0) return false;
    if (state.isAsio) {
      return state.asioDriver.isNotEmpty &&
          state.cachedAsioDrivers.any((d) => d.id == state.asioDriver);
    }
    return true;
  }

  /// Auto-measures round-trip latency whenever the capture path carries our own
  /// output back: a routable loopback capture device, or an interface with
  /// dedicated loopback channels (e.g. a Scarlett's "Loop 1/2", reported via the
  /// excluded-input mask). The measured offset is persisted per device by
  /// [_syncLatencyPersistence].
  void _autoMeasureIfLoopback() {
    if ((state.loopback.isAutoRoutable && state.captureDeviceId.isEmpty) ||
        _repository.state.status.excludedInputMask != 0) {
      _repository.measureLatency();
    }
  }

  /// The engine configuration for the current options + device selection.
  EngineConfig _engineConfig() => EngineConfig(
    sampleRate: state.sampleRate,
    bufferFrames: state.bufferFrames,
    // Channel counts left at 0 (device default): a multichannel interface
    // opens with all its channels; the negotiated counts are reported back.
    maxLoopFrames: _maxLoopFrames(state.maxLoopMinutes, state.sampleRate),
    // An explicitly chosen input device always wins: only auto-route capture to
    // a detected loopback when the user has not pinned a capture device.
    // Otherwise, on hosts where every output exposes a "monitor" capture source
    // (e.g. PipeWire), the loopback auto-route would silently commandeer the
    // capture path and ignore the selected interface. Backend loopback is also
    // irrelevant under ASIO (ASIO holds the device), so force it off there.
    useLoopbackCapture:
        !state.isAsio &&
        state.loopback.isAutoRoutable &&
        state.captureDeviceId.isEmpty,
    playbackDeviceId: state.playbackDeviceId,
    captureDeviceId: state.captureDeviceId,
    backend: state.backend,
    asioDriver: state.asioDriver,
  );

  /// The persisted form of the current options + device selection.
  StoredAudioConfig _storedConfig() => StoredAudioConfig(
    sampleRate: state.sampleRate,
    bufferFrames: state.bufferFrames,
    maxLoopMinutes: state.maxLoopMinutes,
    playbackDeviceId: state.playbackDeviceId,
    captureDeviceId: state.captureDeviceId,
    backend: state.backend,
    asioDriver: state.asioDriver,
  );

  /// Converts a minute cap to engine frames at [sampleRate]; `0` (engine
  /// default) stays `0`. Inverse of [_maxLoopMinutes].
  static int _maxLoopFrames(int minutes, int sampleRate) =>
      minutes <= 0 || sampleRate <= 0 ? 0 : minutes * 60 * sampleRate;

  /// Converts an engine frame cap back to whole minutes at [sampleRate]; `0`
  /// stays `0`. Inverse of [_maxLoopFrames].
  static int _maxLoopMinutes(int? frames, int sampleRate) =>
      frames == null || frames <= 0 || sampleRate <= 0
      ? 0
      : (frames / (60 * sampleRate)).round();

  /// Triggers a loopback round-trip latency measurement.
  void measureLatency() => _repository.measureLatency();

  /// Sets the record offset (latency compensation) directly, in frames — a
  /// manual override for when the automatic measurement isn't available or
  /// reliable. Applied live; persisted per device by [_syncLatencyPersistence]
  /// on the next engine tick (the engine reports it back in the snapshot).
  void setRecordOffset(int frames) =>
      _repository.setRecordOffset(frames < 0 ? 0 : frames);

  void _onLooperState(LooperState looper) {
    emit(_projectFromRepository(looper, current: state));
    _detectConnectivity(looper.status);
    unawaited(_syncLatencyPersistence(looper.status));
  }

  /// Diffs `devicePresent` against the previous tick and raises a transient
  /// lost/restored banner trigger for a pinned device. The system default is
  /// not flagged (it is never auto-restarted, so a banner would be noise).
  void _detectConnectivity(EngineStatus status) {
    // A selected ASIO driver counts as "pinned" too, so losing it raises the
    // banner the same way a lost miniaudio device does.
    final pinned =
        state.playbackDeviceId.isNotEmpty ||
        state.captureDeviceId.isNotEmpty ||
        (state.isAsio && state.asioDriver.isNotEmpty);
    final present = status.devicePresent;
    final previous = _lastDevicePresent;
    _lastDevicePresent = present;
    if (present && status.deviceName.isNotEmpty) {
      _lastPresentDeviceName = status.deviceName;
    }
    if (!pinned || previous == null || previous == present) return;
    emit(
      state.copyWith(
        deviceConnectivity: present
            ? DeviceConnectivity.restored
            : DeviceConnectivity.lost,
        connectivityDeviceName: _lastPresentDeviceName,
      ),
    );
  }

  /// Loads a saved per-device record offset the first time a device connects,
  /// and persists a freshly measured offset so it is remembered next run.
  Future<void> _syncLatencyPersistence(EngineStatus status) async {
    if (!status.isConnected || status.deviceName.isEmpty) return;
    final deviceKey =
        '${status.deviceName}|${status.sampleRate}|${status.bufferFrames}';

    if (_hydratedDeviceKey != deviceKey) {
      _hydratedDeviceKey = deviceKey;
      final saved = await _settings.loadLatencyOffsetFrames(
        device: status.deviceName,
        sampleRate: status.sampleRate,
        bufferFrames: status.bufferFrames,
      );
      if (saved != null && saved > 0) {
        _persistedOffset = saved;
        _repository.setRecordOffset(saved);
        return;
      }
    }

    // Persist a fresh measurement (the engine auto-sets the offset on a
    // successful measurement) so it is restored on the next run.
    final offset = status.recordOffsetFrames;
    if (offset > 0 && offset != _persistedOffset) {
      _persistedOffset = offset;
      unawaited(
        _settings.saveLatencyOffsetFrames(
          device: status.deviceName,
          sampleRate: status.sampleRate,
          bufferFrames: status.bufferFrames,
          frames: offset,
        ),
      );
    }
  }

  AudioSetupState _projectFromRepository(
    LooperState looper, {
    required AudioSetupState current,
    bool hydrateConfig = false,
  }) {
    final engineStatus = looper.status;
    final lastConfig = _repository.lastEngineConfig;

    // The sample-rate / buffer selectors reflect the user's *requested* values,
    // not what the engine negotiated. On hydrate we resolve from the saved
    // config; on every other tick we keep the current selection. (Pulling the
    // engine-reported value back into the selection drifts it from what was
    // picked — and, since changes persist, poisons the saved config. The
    // STATUS table shows the engine's actual values separately.)
    final resolvedSampleRate = hydrateConfig
        ? _resolvedOption(
            negotiated: engineStatus.sampleRate,
            requested: lastConfig?.sampleRate,
            fallback: current.sampleRate,
          )
        : current.sampleRate;

    return current.copyWith(
      sampleRate: resolvedSampleRate,
      bufferFrames: hydrateConfig
          ? _resolvedOption(
              negotiated: engineStatus.bufferFrames,
              requested: lastConfig?.bufferFrames,
              fallback: current.bufferFrames,
            )
          : current.bufferFrames,
      maxLoopMinutes: hydrateConfig
          ? _maxLoopMinutes(lastConfig?.maxLoopFrames, resolvedSampleRate)
          : current.maxLoopMinutes,
      playbackDeviceId: hydrateConfig
          ? lastConfig?.playbackDeviceId ?? current.playbackDeviceId
          : current.playbackDeviceId,
      captureDeviceId: hydrateConfig
          ? lastConfig?.captureDeviceId ?? current.captureDeviceId
          : current.captureDeviceId,
      // Hydrate the requested backend + ASIO driver intent; the negotiated
      // reality is read separately from engineStatus.activeBackend. On Windows
      // (asioOnly) the backend is hardwired to ASIO, coercing a saved
      // backend=miniaudio, and the driver is resolved against the enumeration.
      backend: hydrateConfig
          ? (current.asioOnly
                ? AudioBackend.asio
                : lastConfig?.backend ?? AudioBackend.miniaudio)
          : current.backend,
      asioDriver: hydrateConfig
          ? (current.asioOnly
                ? _resolveAsioDriver(
                    lastConfig?.asioDriver ?? '',
                    current.cachedAsioDrivers,
                  )
                : lastConfig?.asioDriver ?? current.asioDriver)
          : current.asioDriver,
      engineStatus: engineStatus,
      status: engineStatus.isConnected
          ? AudioSetupStatus.running
          : current.status == AudioSetupStatus.error
          ? AudioSetupStatus.error
          : AudioSetupStatus.stopped,
    );
  }

  /// Resolves the ASIO driver to open on Windows: keeps [saved] when it is
  /// still enumerated, otherwise falls back to the first enumerated driver, or
  /// empty when none are installed (the no-driver case).
  String _resolveAsioDriver(String saved, List<AudioDevice> drivers) {
    if (drivers.any((d) => d.id == saved)) return saved;
    return drivers.isEmpty ? '' : drivers.first.id;
  }

  int _resolvedOption({
    required int negotiated,
    required int? requested,
    required int fallback,
  }) {
    if (negotiated > 0) return negotiated;
    if (requested != null && requested > 0) return requested;
    return fallback;
  }

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}
