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
  /// A save (a write-back via [SessionCubit.save] or a
  /// [SessionCubit.saveAs] of a named session) succeeded.
  saved,

  /// A [SessionCubit.loadNamed] succeeded.
  loaded,

  /// A named session was renamed.
  renamed,

  /// A named session was deleted.
  deleted,

  /// [SessionCubit.save] was called with no open session — the UI should open
  /// the Save-As name dialog rather than the cubit silently picking a name.
  saveAsRequested,

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

  /// A save-as / rename targeted a name whose slug already exists.
  nameCollision,

  /// The session bundle's overdub-layer data is corrupt or foreign.
  corruptLayers,

  /// Any other failure (I/O, engine, etc.); see [SessionState.errorMessage].
  unknown,
}

/// State of the [SessionCubit].
///
/// Two logical parts: the **per-action result** ([status] plus [outcome] /
/// [error] / [errorMessage] for the last action) and the **durable catalog**
/// ([currentSessionName] — the document model's open session — and [sessions]
/// — the picker list). The catalog fields survive across action transitions;
/// the result fields describe only the most recent action. Neither is persisted
/// to disk (the current session is a runtime pointer).
class SessionState extends Equatable {
  /// Creates a [SessionState].
  const SessionState({
    this.status = SessionStatus.idle,
    this.outcome,
    this.error,
    this.errorMessage,
    this.currentSessionName,
    this.sessions = const [],
  });

  /// The current action status.
  final SessionStatus status;

  /// Which action succeeded, for localized success messaging.
  final SessionOutcome? outcome;

  /// The classified failure kind, for localized error messaging.
  final SessionError? error;

  /// The raw failure message, for diagnostics / the unknown-error fallback.
  final String? errorMessage;

  /// The name of the session currently open (the document model), or `null`
  /// when none is loaded. A runtime pointer — never persisted.
  final String? currentSessionName;

  /// The saved-session catalog, for the picker.
  final List<SessionSummary> sessions;

  /// Returns a copy for the next emit.
  ///
  /// The **result** fields ([outcome] / [error] / [errorMessage]) are
  /// per-transition: they default to `null` (cleared) unless passed, so a fresh
  /// status never carries a stale result. The **durable** fields
  /// ([currentSessionName] / [sessions]) are preserved unless overridden;
  /// [clearCurrentSession] sets the open-session pointer back to `null`.
  SessionState copyWith({
    SessionStatus? status,
    SessionOutcome? outcome,
    SessionError? error,
    String? errorMessage,
    String? currentSessionName,
    bool clearCurrentSession = false,
    List<SessionSummary>? sessions,
  }) => SessionState(
    status: status ?? this.status,
    outcome: outcome,
    error: error,
    errorMessage: errorMessage,
    currentSessionName: clearCurrentSession
        ? null
        : (currentSessionName ?? this.currentSessionName),
    sessions: sessions ?? this.sessions,
  );

  @override
  List<Object?> get props => [
    status,
    outcome,
    error,
    errorMessage,
    currentSessionName,
    sessions,
  ];
}
