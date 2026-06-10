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

/// State of the [SessionCubit]: the current action [status] and a
/// human-readable [message] for the most recent outcome.
class SessionState extends Equatable {
  /// Creates a [SessionState].
  const SessionState({this.status = SessionStatus.idle, this.message});

  /// The current action status.
  final SessionStatus status;

  /// A success or failure message for the most recent action, if any.
  final String? message;

  @override
  List<Object?> get props => [status, message];
}
