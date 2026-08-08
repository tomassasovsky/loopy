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

  /// Releases a held reading once [holdFor] has passed with nothing fresh.
  ///
  /// A timer rather than a count of frames: [LooperRepository] only emits when
  /// the projected state CHANGES, so on a still rig (transport stopped, silent
  /// input) the "no pitch" frame arrives exactly once and no amount of counting
  /// would ever reach the end of the hold. The note would then sit on screen
  /// forever, which is the one thing the hold exists to prevent.
  Timer? _holdTimer;

  /// Selects the hardware [input] to listen to, arming it if the face is open.
  void selectInput(int input) {
    if (input == state.input) return;
    emit(state.copyWith(input: input, hz: 0, clearPitch: true));
    _cancelHold();
    if (state.isOpen) _repository.setTunerInput(input: input);
  }

  /// Arms the engine on the selected input. Called when the face appears.
  ///
  /// Resolved against the rig on the way in rather than waiting for the first
  /// projection: a stale or loopback selection would otherwise be analysed for
  /// the frame in between, which is long enough to put a reading on screen.
  void arm() {
    if (state.isOpen) return;
    final status = _repository.state.status;
    final input = _tunableInput(
      state.input,
      status.inputChannels,
      status.excludedInputMask,
    );
    emit(state.copyWith(isOpen: true, input: input));
    _repository.setTunerInput(input: input);
  }

  /// The input to actually listen on: [wanted] when this rig has it and it is
  /// worth tuning, else the first channel that is, else `-1`.
  ///
  /// Two things disqualify a channel. It may simply not exist — a selection
  /// carried over from a wider interface, which the engine DISARMS rather than
  /// clamps, so leaving it would sit dead. Or it may be a loopback capture,
  /// which carries the console's own output back: the engine's tuner tap does
  /// not filter those, so tuning one would report the pitch of the loop that
  /// is playing as though something were plugged into that socket. Neither is
  /// positional — the loopback mask comes from per-channel NAMES, so a virtual
  /// device can have channel 0 excluded and an all-loopback device every
  /// channel — which is why this resolves rather than clamps.
  static int _tunableInput(int wanted, int channels, int excluded) {
    // Nothing known yet (no device open): leave the choice alone rather than
    // resolving it against a rig that has not been reported.
    if (channels <= 0) return wanted;
    bool tunable(int input) =>
        input >= 0 && input < channels && excluded & (1 << input) == 0;
    if (tunable(wanted)) return wanted;
    for (var input = 0; input < channels; input++) {
      if (tunable(input)) return input;
    }
    return -1;
  }

  /// Disarms the engine. Called when the face leaves, so detection stops.
  void disarm() {
    if (!state.isOpen) return;
    _repository.setTunerInput(input: -1);
    emit(state.copyWith(isOpen: false, hz: 0, clearPitch: true));
    _cancelHold();
  }

  void _onLooperState(LooperState looper) {
    // Fold a selection this rig cannot tune onto one it can, the moment the
    // rig says so — see [_tunableInput] for what disqualifies a channel. `-1`
    // when there is nothing worth tuning at all, which disarms the engine
    // rather than leaving it on a loopback.
    final channels = looper.status.inputChannels;
    final wanted = _tunableInput(
      state.input,
      channels,
      looper.status.excludedInputMask,
    );
    if (wanted != state.input) {
      // [selectInput] has already re-armed if the face is open, and this
      // frame's reading belongs to the input we just left, so there is nothing
      // here worth reading.
      selectInput(wanted);
      return;
    }

    if (!state.isOpen) return;
    final reading = looper.tuner;

    // Draw only what the engine heard on the input we are actually showing. A
    // snapshot polled between a tab tap and the engine consuming the switch
    // still carries the PREVIOUS input's pitch, and drawing it under the new
    // tab's label is a lie the reading itself can rule out.
    //
    // The same mismatch is also the watchdog. Arming is fire-and-forget —
    // [LooperRepository.setTunerInput] posts through a fixed-size command ring
    // that a rig restore can fill — so both an arm and a SWITCH can be dropped,
    // and nothing else would ever notice: [arm] ran once, on the way in, and
    // [selectInput] only runs on a tap. Disagreement is the engine telling us
    // the push did not land, whether it left the tuner disarmed (`-1`, which
    // never matches a real input) or still listening to the input before this
    // one, so push again. Idempotent, and the clamp above is what stops a
    // selection the rig has not got from making this a push every frame.
    if (reading.input != state.input) {
      if (channels > 0) _repository.setTunerInput(input: state.input);
      return;
    }

    if (reading.hasPitch && reading.confidence >= minConfidence) {
      _cancelHold();
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
    if (!state.isStale) emit(state.copyWith(isStale: true));
    _holdTimer ??= Timer(holdFor, _releaseHold);
  }

  void _releaseHold() {
    _holdTimer = null;
    if (state.pitch == null) return;
    emit(state.copyWith(hz: 0, clearPitch: true, isStale: false));
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  @override
  Future<void> close() {
    // Never leave the engine analysing an input for a face that is gone.
    if (state.isOpen) _repository.setTunerInput(input: -1);
    _cancelHold();
    unawaited(_subscription.cancel());
    return super.close();
  }
}
