part of 'session_cubit.dart';

/// Lifecycle of a session persistence action.
enum SessionStatus {
  /// No action in progress.
  idle,

  /// An action is running.
  working,

  /// The last action succeeded.
  success,

  /// The last action failed.
  failure,
}

/// Which session action succeeded, for localized UI messaging.
enum SessionOutcome {
  /// [SessionCubit.saveSession] succeeded.
  saved,

  /// [SessionCubit.loadSession] succeeded.
  loaded,

  /// [SessionCubit.exportMixdown] succeeded.
  mixdownExported,

  /// [SessionCubit.exportStems] succeeded.
  stemsExported,
}

/// A classified failure kind, so the UI can show a localized, human-readable
/// message instead of a raw `toString()`.
enum SessionError {
  /// The session's sample rate differs from the running device's.
  sampleRateMismatch,

  /// The session was written by a newer, incompatible version of the app.
  unsupportedVersion,

  /// Any other failure (I/O, engine, etc.); see [SessionState.errorMessage].
  unknown,
}

/// State of the [SessionCubit]: the current action [status] and a [outcome]
/// for the most recent successful action, or a classified [error] (with a raw
/// [errorMessage] for diagnostics) if it failed.
class SessionState extends Equatable {
  /// Creates a [SessionState].
  const SessionState({
    this.status = SessionStatus.idle,
    this.outcome,
    this.error,
    this.errorMessage,
  });

  /// The current action status.
  final SessionStatus status;

  /// Which action succeeded, for localized success messaging.
  final SessionOutcome? outcome;

  /// The classified failure kind, for localized error messaging.
  final SessionError? error;

  /// The raw failure message, for diagnostics / the unknown-error fallback.
  final String? errorMessage;

  @override
  List<Object?> get props => [status, outcome, error, errorMessage];
}
