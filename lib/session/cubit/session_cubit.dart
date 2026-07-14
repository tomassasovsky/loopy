import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/session/session_mapping.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:session_repository/session_repository.dart';

part 'session_state.dart';

/// Drives session persistence (save / load / export) and the named-session
/// catalog (list / save-as / rename / delete), tracking the open session so a
/// plain [save] writes back without re-prompting (the document model).
///
/// Composes three repositories at the bloc level (repositories never import
/// repositories): the session repository does the file I/O + owns the catalog
/// layout, the looper repository — the single owner of looper state — applies a
/// loaded session to the engine and supplies the live chains a save captures,
/// and the performance repository is disarmed+finalized before a load applies
/// (a session load while armed would otherwise pull the rug out from under an
/// in-progress capture).
class SessionCubit extends Cubit<SessionState> {
  /// Creates a [SessionCubit] backed by [repository], [looper], and
  /// [performance].
  ///
  /// [exportDirectory] resolves the directory a mixdown / stems are written to;
  /// the named-session methods go through [repository]'s catalog instead.
  /// Injecting it keeps the cubit testable.
  SessionCubit({
    required SessionRepository repository,
    required LooperRepository looper,
    required PerformanceRepository performance,
    required Future<String> Function() exportDirectory,
  }) : _repository = repository,
       _looper = looper,
       _performance = performance,
       _exportDirectory = exportDirectory,
       super(const SessionState());

  final SessionRepository _repository;
  final LooperRepository _looper;
  final PerformanceRepository _performance;
  final Future<String> Function() _exportDirectory;

  // ---- exports (a separate action from the session catalog) ----

  /// Exports a mixed-down WAV of the live rig into the export directory.
  Future<void> exportMixdown() => _run(() async {
    await _repository.exportMixdown(
      '${await _exportDirectory()}/${SessionRepository.mixdownName}',
    );
    return const _ActionResult(SessionOutcome.mixdownExported);
  });

  /// Exports each track as a separate stem WAV under a `stems` folder.
  Future<void> exportStems() => _run(() async {
    await _repository.exportStems('${await _exportDirectory()}/stems');
    return const _ActionResult(SessionOutcome.stemsExported);
  });

  // ---- named-session catalog (the document model) ----

  /// Reloads the saved-session catalog into state (for the picker). A quiet
  /// update — no working/success cycle.
  Future<void> refreshSessions() async {
    final sessions = await _repository.listSessions();
    if (isClosed) return;
    emit(state.copyWith(sessions: sessions));
  }

  /// Saves the live rig as a NEW named session and makes it current. Rejects a
  /// duplicate slug with [SessionError.nameCollision] and writes nothing.
  Future<void> saveAs(String name) => _run(() async {
    final slug = _slugOf(name);
    if ((await _repository.listSessions()).any((s) => s.name == slug)) {
      throw SessionNameCollision(slug: slug);
    }
    await _repository.save(
      await _repository.bundlePath(name),
      chains: chainsFromLooper(_looper),
    );
    return _ActionResult(
      SessionOutcome.saved,
      currentName: slug,
      sessions: await _repository.listSessions(),
    );
  });

  /// Writes the live rig back to the open session with no prompt. With no open
  /// session, signals the UI to open Save-As ([SessionOutcome.saveAsRequested])
  /// rather than silently picking a name.
  Future<void> save() {
    final name = state.currentSessionName;
    if (name == null) {
      emit(
        state.copyWith(
          status: SessionStatus.idle,
          outcome: SessionOutcome.saveAsRequested,
        ),
      );
      return Future<void>.value();
    }
    return _run(() async {
      await _repository.save(
        await _repository.bundlePath(name),
        chains: chainsFromLooper(_looper),
      );
      return const _ActionResult(SessionOutcome.saved);
    });
  }

  /// Loads named session [name] into the engine through the looper repository
  /// (the one apply path), makes it current, and refreshes the catalog.
  ///
  /// Auto-disarms and finalizes an in-progress performance-recording capture
  /// first — applying a loaded session mid-capture would otherwise pull the
  /// rug out from under it. The finalize + render run through the same path a
  /// manual disarm does; `PerformanceRecorderCubit` observes the repository's
  /// status stream, so it reflects this disarm too even though it was never
  /// the one to call it.
  Future<void> loadNamed(String name) => _run(() async {
    await _performance.disarmAndFinalize();
    final bundle = await _repository.read(await _repository.bundlePath(name));
    await _looper.applySession(rigFromBundle(bundle));
    return _ActionResult(
      SessionOutcome.loaded,
      currentName: _slugOf(name),
      sessions: await _repository.listSessions(),
    );
  });

  /// Renames session [from] to [to]. If [from] is the open session, the current
  /// pointer follows the rename. A slug collision surfaces as
  /// [SessionError.nameCollision] (the repository is the authority).
  Future<void> renameSession(String from, String to) => _run(() async {
    await _repository.renameSession(from, to);
    final open = state.currentSessionName;
    return _ActionResult(
      SessionOutcome.renamed,
      currentName: open == from ? _slugOf(to) : open,
      sessions: await _repository.listSessions(),
    );
  });

  /// Deletes session [name]. If it is the open session, the current pointer is
  /// cleared — the live rig keeps playing (the engine is never touched here).
  Future<void> deleteSession(String name) => _run(() async {
    await _repository.deleteSession(name);
    final wasOpen = state.currentSessionName == _slugOf(name);
    return _ActionResult(
      SessionOutcome.deleted,
      clearCurrent: wasOpen,
      sessions: await _repository.listSessions(),
    );
  });

  /// Duplicates saved session [from] to a NEW named session [to] (a copy on
  /// disk; the open session is unchanged). A slug collision surfaces as
  /// [SessionError.nameCollision] (the repository is the authority).
  Future<void> duplicateSession(String from, String to) => _run(() async {
    await _repository.duplicateSession(from, to);
    return _ActionResult(
      SessionOutcome.saved,
      sessions: await _repository.listSessions(),
    );
  });

  /// The slug [name] resolves to, or throws [ArgumentError] when it sanitizes
  /// to nothing (the same rule the repository's `bundlePath` enforces).
  String _slugOf(String name) {
    final slug = sessionSlug(name);
    if (slug == null) {
      throw ArgumentError.value(name, 'name', 'not a valid session name');
    }
    return slug;
  }

  /// Runs [action] with the standard working → success/failure envelope,
  /// folding its durable-catalog changes into the next state and preserving the
  /// open session + list across the transition.
  Future<void> _run(Future<_ActionResult> Function() action) async {
    emit(state.copyWith(status: SessionStatus.working));
    try {
      final result = await action();
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.success,
          outcome: result.outcome,
          currentSessionName: result.currentName,
          clearCurrentSession: result.clearCurrent,
          sessions: result.sessions,
        ),
      );
    } on SessionException catch (error) {
      // Recoverable, user-facing refusals: classify so the UI can localize.
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          error: _classify(error),
          errorMessage: '$error',
        ),
      );
    } on Object catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          error: SessionError.unknown,
          errorMessage: '$error',
        ),
      );
    }
  }

  static SessionError _classify(SessionException error) => switch (error) {
    SessionSampleRateMismatch() => SessionError.sampleRateMismatch,
    SessionUnsupportedVersion() => SessionError.unsupportedVersion,
    SessionNameCollision() => SessionError.nameCollision,
    SessionCorruptLayers() => SessionError.corruptLayers,
  };
}

/// What a session action changed: its success [outcome] plus any durable
/// catalog updates to fold into the next state.
class _ActionResult {
  const _ActionResult(
    this.outcome, {
    this.currentName,
    this.clearCurrent = false,
    this.sessions,
  });

  final SessionOutcome outcome;
  final String? currentName;
  final bool clearCurrent;
  final List<SessionSummary>? sessions;
}
