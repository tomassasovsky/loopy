part of 'audio_setup_cubit.dart';

/// Whether the audio device is currently open.
enum AudioSetupStatus {
  /// The engine is stopped; the device is closed.
  stopped,

  /// The engine is running; the device is open.
  running,

  /// The engine failed to start.
  error,
}

/// State for the audio setup feature: the user's requested device options plus
/// the live engine status projected from the repository.
class AudioSetupState extends Equatable {
  /// Creates an [AudioSetupState].
  const AudioSetupState({
    this.sampleRate = 48000,
    this.bufferFrames = 128,
    this.monitorInput = true,
    this.status = AudioSetupStatus.stopped,
    this.engineStatus = const EngineStatus(),
    this.errorMessage,
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

  /// Whether captured input is monitored to the output.
  final bool monitorInput;

  /// High-level lifecycle status.
  final AudioSetupStatus status;

  /// Live engine/device status from the repository.
  final EngineStatus engineStatus;

  /// A human-readable error when [status] is [AudioSetupStatus.error].
  final String? errorMessage;

  /// Selectable sample rates.
  static const sampleRates = [44100, 48000, 96000];

  /// Selectable buffer sizes.
  static const bufferSizes = [64, 128, 256, 512];

  /// Returns a copy with the given fields replaced.
  AudioSetupState copyWith({
    int? sampleRate,
    int? bufferFrames,
    bool? monitorInput,
    AudioSetupStatus? status,
    EngineStatus? engineStatus,
    String? errorMessage,
  }) {
    return AudioSetupState(
      sampleRate: sampleRate ?? this.sampleRate,
      bufferFrames: bufferFrames ?? this.bufferFrames,
      monitorInput: monitorInput ?? this.monitorInput,
      status: status ?? this.status,
      engineStatus: engineStatus ?? this.engineStatus,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [
    sampleRate,
    bufferFrames,
    monitorInput,
    status,
    engineStatus,
    errorMessage,
  ];
}
