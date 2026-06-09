import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'audio_setup_state.dart';

/// Manages audio device options (sample rate, buffer size, input monitoring),
/// starts/stops the engine through the repository, and surfaces live engine
/// status and latency measurements.
class AudioSetupCubit extends Cubit<AudioSetupState> {
  /// Creates an [AudioSetupCubit] backed by [repository], persisting per-device
  /// latency calibration through [settings].
  AudioSetupCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const AudioSetupState()) {
    _subscription = _repository.looperState.listen(_onLooperState);

    // Hydrate from the repository immediately — [looperState] is a broadcast
    // stream that does not replay, so a new cubit would otherwise show defaults
    // until the next engine tick even when the device is already open.
    emit(
      _projectFromRepository(
        _repository.state,
        current: state.copyWith(
          loopback: _repository.detectLoopback(),
          devices: _repository.devices(),
        ),
        hydrateConfig: true,
      ),
    );
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  late final StreamSubscription<LooperState> _subscription;

  /// The device profile we've loaded a saved offset for, to load only once.
  String? _hydratedDeviceKey;

  /// The last record-offset value we persisted, to avoid redundant writes.
  int? _persistedOffset;

  /// Previous pinned-device presence, to detect lost/restored transitions; and
  /// the last device name seen while present, so a disconnect banner can name
  /// the device even after the snapshot stops reporting it.
  bool? _lastDevicePresent;
  String _lastPresentDeviceName = '';

  /// Selects the requested sample rate (applied on the next start).
  void setSampleRate(int sampleRate) =>
      emit(state.copyWith(sampleRate: sampleRate));

  /// Selects the requested buffer size (applied on the next start).
  void setBufferFrames(int bufferFrames) =>
      emit(state.copyWith(bufferFrames: bufferFrames));

  /// Toggles input monitoring (applied on the next start).
  void setMonitorInput({required bool monitorInput}) =>
      emit(state.copyWith(monitorInput: monitorInput));

  /// Toggles merging input channels to mono (applied on the next start).
  void setMergeToMono({required bool mergeToMono}) =>
      emit(state.copyWith(mergeToMono: mergeToMono));

  /// Selects the playback device to open (empty id = system default). Persists
  /// the choice and, when the engine is already running, reopens on it now.
  void setPlaybackDevice(String deviceId) =>
      _selectDevice(playbackDeviceId: deviceId);

  /// Selects the capture device to open (empty id = system default).
  void setCaptureDevice(String deviceId) =>
      _selectDevice(captureDeviceId: deviceId);

  void _selectDevice({String? playbackDeviceId, String? captureDeviceId}) {
    emit(
      state.copyWith(
        playbackDeviceId: playbackDeviceId,
        captureDeviceId: captureDeviceId,
      ),
    );
    unawaited(_settings.saveAudioConfig(_storedConfig()));
    // Apply immediately when running so the picked device opens now; otherwise
    // it is used on the next start / auto-start.
    if (state.status == AudioSetupStatus.running) {
      _repository.stopEngine();
      final result = _repository.startEngine(_engineConfig());
      if (!result.isOk) {
        emit(
          state.copyWith(
            status: AudioSetupStatus.error,
            errorMessage: 'Failed to open device: ${result.name}',
          ),
        );
      }
    }
  }

  /// The engine configuration for the current options + device selection.
  EngineConfig _engineConfig() => EngineConfig(
    sampleRate: state.sampleRate,
    bufferFrames: state.bufferFrames,
    // Channel counts left at 0 (device default): a multichannel interface
    // opens with all its channels; the negotiated counts are reported back.
    passthrough: state.monitorInput,
    mergeToMono: state.mergeToMono,
    useLoopbackCapture: state.loopback.isAutoRoutable,
    playbackDeviceId: state.playbackDeviceId,
    captureDeviceId: state.captureDeviceId,
  );

  /// The persisted form of the current options + device selection.
  StoredAudioConfig _storedConfig() => StoredAudioConfig(
    sampleRate: state.sampleRate,
    bufferFrames: state.bufferFrames,
    monitorInput: state.monitorInput,
    mergeToMono: state.mergeToMono,
    playbackDeviceId: state.playbackDeviceId,
    captureDeviceId: state.captureDeviceId,
  );

  /// Opens the audio device with the current options.
  void start() {
    final result = _repository.startEngine(_engineConfig());
    if (result.isOk) {
      emit(state.copyWith(status: AudioSetupStatus.running));
      // Remember these options so the engine can auto-start on the next launch.
      unawaited(_settings.saveAudioConfig(_storedConfig()));
      // With a routable loopback the capture carries our output, so we can
      // measure round-trip latency automatically (a digital-path estimate).
      if (state.loopback.isAutoRoutable) _repository.measureLatency();
    } else {
      emit(
        state.copyWith(
          status: AudioSetupStatus.error,
          errorMessage: 'Failed to start audio: ${result.name}',
        ),
      );
    }
  }

  /// Closes the audio device.
  void stop() {
    _repository.stopEngine();
    emit(state.copyWith(status: AudioSetupStatus.stopped));
  }

  /// Triggers a loopback round-trip latency measurement.
  void measureLatency() => _repository.measureLatency();

  void _onLooperState(LooperState looper) {
    emit(_projectFromRepository(looper, current: state));
    _detectConnectivity(looper.status);
    unawaited(_syncLatencyPersistence(looper.status));
  }

  /// Diffs `devicePresent` against the previous tick and raises a transient
  /// lost/restored banner trigger for a pinned device. The system default is
  /// not flagged (it is never auto-restarted, so a banner would be noise).
  void _detectConnectivity(EngineStatus status) {
    final pinned =
        state.playbackDeviceId.isNotEmpty || state.captureDeviceId.isNotEmpty;
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

    return current.copyWith(
      sampleRate: hydrateConfig
          ? _resolvedOption(
              negotiated: engineStatus.sampleRate,
              requested: lastConfig?.sampleRate,
              fallback: current.sampleRate,
            )
          : engineStatus.isConnected && engineStatus.sampleRate > 0
          ? engineStatus.sampleRate
          : current.sampleRate,
      bufferFrames: hydrateConfig
          ? _resolvedOption(
              negotiated: engineStatus.bufferFrames,
              requested: lastConfig?.bufferFrames,
              fallback: current.bufferFrames,
            )
          : engineStatus.isConnected && engineStatus.bufferFrames > 0
          ? engineStatus.bufferFrames
          : current.bufferFrames,
      monitorInput: hydrateConfig
          ? lastConfig?.passthrough ?? current.monitorInput
          : current.monitorInput,
      mergeToMono: hydrateConfig
          ? lastConfig?.mergeToMono ?? current.mergeToMono
          : current.mergeToMono,
      playbackDeviceId: hydrateConfig
          ? lastConfig?.playbackDeviceId ?? current.playbackDeviceId
          : current.playbackDeviceId,
      captureDeviceId: hydrateConfig
          ? lastConfig?.captureDeviceId ?? current.captureDeviceId
          : current.captureDeviceId,
      engineStatus: engineStatus,
      status: engineStatus.isConnected
          ? AudioSetupStatus.running
          : current.status == AudioSetupStatus.error
          ? AudioSetupStatus.error
          : AudioSetupStatus.stopped,
    );
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
