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
    _subscription = _repository.looperState.listen((s) {
      emit(
        state.copyWith(
          engineStatus: s.status,
          status: s.status.isConnected
              ? AudioSetupStatus.running
              : state.status == AudioSetupStatus.error
              ? AudioSetupStatus.error
              : AudioSetupStatus.stopped,
        ),
      );
    });
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

  /// Opens the audio device with the current options.
  void start() {
    final result = _repository.startEngine(
      EngineConfig(
        sampleRate: state.sampleRate,
        bufferFrames: state.bufferFrames,
        channels: 2,
        passthrough: state.monitorInput,
      ),
    );
    if (result.isOk) {
      emit(state.copyWith(status: AudioSetupStatus.running));
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

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}
