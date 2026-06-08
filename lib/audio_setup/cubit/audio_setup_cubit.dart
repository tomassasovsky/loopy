import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

part 'audio_setup_state.dart';

/// Manages audio device options (sample rate, buffer size, input monitoring),
/// starts/stops the engine through the repository, and surfaces live engine
/// status and latency measurements.
class AudioSetupCubit extends Cubit<AudioSetupState> {
  /// Creates an [AudioSetupCubit] backed by [repository].
  AudioSetupCubit({required LooperRepository repository})
    : _repository = repository,
      super(const AudioSetupState()) {
    _subscription = _repository.looperState.listen(_onLooperState);

    // Hydrate from the repository immediately — [looperState] is a broadcast
    // stream that does not replay, so a new cubit would otherwise show defaults
    // until the next engine tick even when the device is already open.
    emit(
      _projectFromRepository(
        _repository.state,
        current: state.copyWith(loopback: _repository.detectLoopback()),
        hydrateConfig: true,
      ),
    );
  }

  final LooperRepository _repository;
  late final StreamSubscription<LooperState> _subscription;

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

  /// Opens the audio device with the current options.
  void start() {
    final result = _repository.startEngine(
      EngineConfig(
        sampleRate: state.sampleRate,
        bufferFrames: state.bufferFrames,
        channels: 2,
        passthrough: state.monitorInput,
        mergeToMono: state.mergeToMono,
        useLoopbackCapture: state.loopback.isAutoRoutable,
      ),
    );
    if (result.isOk) {
      emit(state.copyWith(status: AudioSetupStatus.running));
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
