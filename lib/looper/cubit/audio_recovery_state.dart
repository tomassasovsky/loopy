part of 'audio_recovery_cubit.dart';

/// Whether the console is waiting for a pinned audio device to (re)appear so it
/// can auto-start the engine without a pointer.
enum AudioRecoveryStatus {
  /// Nothing to recover — the engine is running, has run this session (the
  /// in-repo reconnect supervisor owns recovery from here), or no pinned device
  /// was configured.
  idle,

  /// The engine has not started this session and the saved pinned device is not
  /// yet present; the cubit is watching for it and will auto-start on arrival.
  waitingForDevice,
}

/// State of [AudioRecoveryCubit].
class AudioRecoveryState extends Equatable {
  /// Creates an [AudioRecoveryState].
  const AudioRecoveryState({this.status = AudioRecoveryStatus.idle});

  /// The current recovery status.
  final AudioRecoveryStatus status;

  @override
  List<Object?> get props => [status];
}
