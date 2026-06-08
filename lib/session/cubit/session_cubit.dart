import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:session_repository/session_repository.dart';

part 'session_state.dart';

/// Drives session persistence actions (save / load / export) and surfaces their
/// outcome so the UI can show progress and a success/failure message.
class SessionCubit extends Cubit<SessionState> {
  /// Creates a [SessionCubit] backed by [repository].
  ///
  /// [directory] resolves the session bundle directory lazily (e.g. the app's
  /// documents folder); injecting it keeps the cubit testable.
  SessionCubit({
    required SessionRepository repository,
    required Future<String> Function() directory,
  }) : _repository = repository,
       _directory = directory,
       super(const SessionState());

  final SessionRepository _repository;
  final Future<String> Function() _directory;

  /// Saves the current session (manifest + stems + mixdown).
  Future<void> saveSession() => _run(_repository.save, 'Session saved');

  /// Loads the saved session back into the engine.
  Future<void> loadSession() => _run(_repository.load, 'Session loaded');

  /// Exports a mixed-down WAV of the current session.
  Future<void> exportMixdown() => _run(
    (dir) => _repository.exportMixdown('$dir/${SessionRepository.mixdownName}'),
    'Mixdown exported',
  );

  Future<void> _run(
    Future<void> Function(String directory) action,
    String successMessage,
  ) async {
    emit(const SessionState(status: SessionStatus.working));
    try {
      await action(await _directory());
      emit(
        SessionState(status: SessionStatus.success, message: successMessage),
      );
    } on Object catch (error) {
      emit(SessionState(status: SessionStatus.failure, message: '$error'));
    }
  }
}
