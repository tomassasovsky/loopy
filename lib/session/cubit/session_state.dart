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

/// State of the [SessionCubit]: the current action [status] and a
/// [outcome] for the most recent action, or a [errorMessage] if it failed.
class SessionState extends Equatable {
  /// Creates a [SessionState].
  const SessionState({
    this.status = SessionStatus.idle,
    this.outcome,
    this.errorMessage,
  });

  /// The current action status.
  final SessionStatus status;

  /// Which action succeeded, for localized success messaging.
  final SessionOutcome? outcome;

  /// A failure message for the most recent action, if any.
  final String? errorMessage;

  @override
  List<Object?> get props => [status, outcome, errorMessage];
}
