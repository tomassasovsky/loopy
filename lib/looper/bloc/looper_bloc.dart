import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

part 'looper_event.dart';

/// Drives the looper transport and track from UI/controller events, and mirrors
/// the repository's [LooperState] stream as the bloc state.
///
/// Commands are forwarded to the repository; the resulting engine state flows
/// back through the stream, keeping the repository the single source of truth.
class LooperBloc extends Bloc<LooperEvent, LooperState> {
  /// Creates a [LooperBloc] backed by [repository].
  LooperBloc({required LooperRepository repository})
    : _repository = repository,
      super(const LooperState()) {
    on<LooperStateUpdated>((event, emit) => emit(event.state));
    on<LooperRecordPressed>((_, _) => _repository.record());
    on<LooperStopPressed>((_, _) => _repository.stopTrack());
    on<LooperPlayPressed>((_, _) => _repository.play());
    on<LooperClearPressed>((_, _) => _repository.clear());
    on<LooperUndoPressed>((_, _) => _repository.undo());
    on<LooperVolumeChanged>((event, _) => _repository.setVolume(event.volume));
    on<LooperMuteToggled>(
      (_, _) => _repository.setMute(muted: !state.track.muted),
    );

    _subscription = _repository.looperState.listen(
      (s) => add(LooperStateUpdated(s)),
    );
  }

  final LooperRepository _repository;
  late final StreamSubscription<LooperState> _subscription;

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}
