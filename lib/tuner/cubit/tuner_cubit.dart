import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/tuner/pitch.dart';

part 'tuner_state.dart';

/// Drives the chromatic tuner face: which input it listens to, and what the
/// engine is currently hearing on it.
///
/// **Arms on show, disarms on hide.** Detection is gated in the engine on the
/// armed input, so a closed tuner costs one atomic load per audio block. That
/// is the whole reason [arm] and [disarm] exist rather than the tuner simply
/// running whenever the engine does.
///
/// The cubit holds the last confident reading for a short decay rather than
/// following the engine frame for frame. A plucked string is periodic for a
/// moment and then is not, so a needle wired straight to the snapshot would
/// snap back to "no signal" between picks — the reading is what the player
/// last played, until it is old enough not to be.
class TunerCubit extends Cubit<TunerState> {
  /// Creates a [TunerCubit] following [repository].
  TunerCubit({required LooperRepository repository})
    : _repository = repository,
      super(const TunerState()) {
    _subscription = _repository.looperState.listen(_onLooperState);
  }

  final LooperRepository _repository;
  late final StreamSubscription<LooperState> _subscription;

  /// How long a confident reading survives without a fresh one.
  ///
  /// Long enough to ride out the gap between picks and the decay of a note,
  /// short enough that walking away from the instrument clears the display
  /// rather than leaving a stale note on screen.
  static const Duration holdFor = Duration(milliseconds: 1200);

  /// Below this, a frame is too aperiodic to believe. Picked to match the
  /// engine's own voiced/unvoiced threshold rather than a second opinion.
  static const double minConfidence = 0.5;

  /// Frames since the last confident reading, counted rather than timed so the
  /// hold does not depend on a wall clock in tests.
  int _staleFrames = 0;

  /// The projection cadence, used to turn [holdFor] into a frame count.
  static const Duration _frame = Duration(milliseconds: 16);

  /// Selects the hardware [input] to listen to, arming it if the face is open.
  void selectInput(int input) {
    if (input == state.input) return;
    emit(state.copyWith(input: input, hz: 0, clearPitch: true));
    _staleFrames = 0;
    if (state.isOpen) _repository.setTunerInput(input: input);
  }

  /// Arms the engine on the selected input. Called when the face appears.
  void arm() {
    if (state.isOpen) return;
    emit(state.copyWith(isOpen: true));
    _repository.setTunerInput(input: state.input);
  }

  /// Disarms the engine. Called when the face leaves, so detection stops.
  void disarm() {
    if (!state.isOpen) return;
    _repository.setTunerInput(input: -1);
    emit(state.copyWith(isOpen: false, hz: 0, clearPitch: true));
    _staleFrames = 0;
  }

  void _onLooperState(LooperState looper) {
    if (!state.isOpen) return;
    final reading = looper.tuner;

    if (reading.hasPitch && reading.confidence >= minConfidence) {
      _staleFrames = 0;
      emit(
        state.copyWith(
          hz: reading.hz,
          pitch: pitchFromHz(reading.hz),
          isStale: false,
        ),
      );
      return;
    }

    // No usable pitch this frame. Hold what was last heard until the hold
    // expires, then clear — a needle that keeps pointing at a note nobody is
    // playing is worse than one that admits it has nothing.
    if (state.pitch == null) return;
    _staleFrames++;
    final held = holdFor.inMilliseconds ~/ _frame.inMilliseconds;
    if (_staleFrames < held) {
      if (!state.isStale) emit(state.copyWith(isStale: true));
      return;
    }
    emit(state.copyWith(hz: 0, clearPitch: true, isStale: false));
    _staleFrames = 0;
  }

  @override
  Future<void> close() {
    // Never leave the engine analysing an input for a face that is gone.
    if (state.isOpen) _repository.setTunerInput(input: -1);
    unawaited(_subscription.cancel());
    return super.close();
  }
}
