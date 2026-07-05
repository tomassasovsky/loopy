import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/session/session_mapping.dart';
import 'package:session_repository/session_repository.dart';

part 'session_state.dart';

/// Drives session persistence actions (save / load / export) and surfaces their
/// outcome so the UI can show progress and a success/failure message.
///
/// Composes the two repositories at the bloc level (repositories never import
/// repositories): the session repository does the file I/O, the looper
/// repository — the single owner of looper state — applies a loaded session
/// to the engine and supplies the live chains a save captures.
class SessionCubit extends Cubit<SessionState> {
  /// Creates a [SessionCubit] backed by [repository] and [looper].
  ///
  /// [directory] resolves the session bundle directory lazily (e.g. the app's
  /// documents folder); injecting it keeps the cubit testable.
  SessionCubit({
    required SessionRepository repository,
    required LooperRepository looper,
    required Future<String> Function() directory,
  }) : _repository = repository,
       _looper = looper,
       _directory = directory,
       super(const SessionState());

  final SessionRepository _repository;
  final LooperRepository _looper;
  final Future<String> Function() _directory;

  /// Saves the current session (manifest + stems + mixdown), capturing the
  /// live effect chains from the looper repository (the rig — not settings — is
  /// the truth being saved).
  Future<void> saveSession() => _run(
    (directory) =>
        _repository.save(directory, chains: chainsFromLooper(_looper)),
    SessionOutcome.saved,
  );

  /// Loads the saved session back into the engine: reads the bundle, then
  /// applies it through the looper repository (the one apply path).
  Future<void> loadSession() => _run((directory) async {
    final bundle = await _repository.read(directory);
    await _looper.applySession(rigFromBundle(bundle));
  }, SessionOutcome.loaded);

  /// Exports a mixed-down WAV of the current session.
  Future<void> exportMixdown() => _run(
    (dir) => _repository.exportMixdown('$dir/${SessionRepository.mixdownName}'),
    SessionOutcome.mixdownExported,
  );

  /// Exports each track as a separate stem WAV under a `stems` folder.
  Future<void> exportStems() => _run(
    (dir) => _repository.exportStems('$dir/stems'),
    SessionOutcome.stemsExported,
  );

  Future<void> _run(
    Future<void> Function(String directory) action,
    SessionOutcome outcome,
  ) async {
    emit(const SessionState(status: SessionStatus.working));
    try {
      await action(await _directory());
      emit(SessionState(status: SessionStatus.success, outcome: outcome));
    } on SessionException catch (error) {
      // Recoverable, user-facing refusals: classify so the UI can localize.
      emit(
        SessionState(
          status: SessionStatus.failure,
          error: switch (error) {
            SessionSampleRateMismatch() => SessionError.sampleRateMismatch,
            SessionUnsupportedVersion() => SessionError.unsupportedVersion,
            // The catalog's collision is not reachable through today's
            // save/load actions; part 2 wires the named CRUD and maps this to a
            // dedicated SessionError.nameCollision. Kept exhaustive so the
            // sealed switch compiles.
            SessionNameCollision() => SessionError.unknown,
          },
          errorMessage: '$error',
        ),
      );
    } on Object catch (error) {
      emit(
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.unknown,
          errorMessage: '$error',
        ),
      );
    }
  }
}
