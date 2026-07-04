import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/model/looper_mode.dart';

part 'control_overlay_state.dart';

/// Owns the closed stored-intent inventory ([ControlOverlayState]) — the ONLY
/// control-surface state that is not derivable from engine truth.
///
/// State flows IN through this cubit's own subscription to
/// `LooperRepository.looperState`: the [_reduce] reducer applies the
/// invalidation table on every snapshot (cursor clamps; excluded/parkedResume
/// members drop when their track empties — which also covers clear-all and
/// session load, since those empty the tracks). Commands flow OUT through
/// `ControlIntents`, never from here — the overlay holds no repository
/// reference, so it can never become a second command path.
///
/// Derived state (the armed set, LEDs, the ring) is computed from
/// `(LooperState × ControlOverlayState)` by the pure functions in
/// `control_projection.dart`; nothing derived is ever stored.
class ControlOverlayCubit extends Cubit<ControlOverlayState> {
  /// Creates a [ControlOverlayCubit] reducing over [looper]'s state stream.
  ControlOverlayCubit({required LooperRepository looper})
    : super(const ControlOverlayState()) {
    _sub = looper.looperState.listen(_reduce);
  }

  late final StreamSubscription<LooperState> _sub;

  /// The one reducer over engine truth: every stored bit's snapshot-driven
  /// invalidation rule lives HERE and nowhere else.
  void _reduce(LooperState looper) {
    var next = state;

    // Cursor: always a valid channel.
    if (looper.tracks.isNotEmpty &&
        (state.cursor < 0 || state.cursor >= looper.tracks.length)) {
      final cursor = state.cursor.clamp(0, looper.tracks.length - 1);
      next = next.copyWith(
        cursor: cursor,
        activeBank: cursor ~/ ControlOverlayState.tracksPerBank,
      );
    }

    // Excluded / parkedResume: membership requires a track that still holds
    // (or is finishing) a loop. An emptied track (undo-to-empty, clear,
    // clear-all, session load) drops out, so no stored set can reference a
    // ghost.
    bool playable(int channel) {
      if (channel < 0 || channel >= looper.tracks.length) return false;
      final t = looper.tracks[channel];
      return t.hasContent || t.isCapturing;
    }

    if (state.excluded.any((c) => !playable(c))) {
      next = next.copyWith(excluded: state.excluded.where(playable).toSet());
    }
    if (state.parkedResume.any((c) => !playable(c))) {
      next = next.copyWith(
        parkedResume: state.parkedResume.where(playable).toSet(),
      );
    }

    if (next != state) emit(next);
  }

  /// Moves the cursor to [channel], following it into its bank (a cursor can
  /// never hide behind the other bank). The one selection every surface
  /// shares.
  void selectTrack(int channel) {
    if (channel < 0 || channel >= _channelCount) return;
    emit(
      state.copyWith(
        cursor: channel,
        activeBank: channel ~/ ControlOverlayState.tracksPerBank,
      ),
    );
  }

  /// Reveals [bank] WITHOUT moving the cursor — the browse flow (e.g. arming
  /// the other bank's tracks in play mode).
  void browseBank(int bank) {
    if (bank < 0 || bank >= ControlOverlayState.bankCount) return;
    emit(state.copyWith(activeBank: bank));
  }

  /// Applies a mode change plus its stored-intent invalidations. The
  /// TRANSPORT side effects of a mode entry (finalizing captures) belong to
  /// `ControlIntents`, which calls this after issuing them.
  void applyMode(LooperMode mode, {required Set<int> parkedResume}) => emit(
    state.copyWith(
      mode: mode,
      excluded: const <int>{},
      parkedResume: parkedResume,
    ),
  );

  /// Records the persisted boot-default mode.
  void setDefaultMode(LooperMode mode) =>
      emit(state.copyWith(defaultMode: mode));

  /// Latches what Rec/Play resumes while parked (park-intent time — engine
  /// truth lags the stop commands by a poll, so latching from a later
  /// snapshot would always capture the empty set).
  void latchParkedResume(Set<int> channels) =>
      emit(state.copyWith(parkedResume: channels));

  /// Toggles [channel]'s membership of the parked-resume set (the play-mode
  /// track press while parked).
  void toggleParkedResume(int channel) {
    final next = {...state.parkedResume};
    if (!next.remove(channel)) next.add(channel);
    emit(state.copyWith(parkedResume: next));
  }

  /// Removes [channel] from the deliberate play-mode exclusions — joining the
  /// mix is the explicit un-exclude.
  void include(int channel) {
    if (!state.excluded.contains(channel)) return;
    emit(state.copyWith(excluded: {...state.excluded}..remove(channel)));
  }

  /// The whole-rig reset (clear-all is an explicit mode action): record mode,
  /// cursor home, no stored play intent — unified across every surface.
  void resetForClearAll() => emit(
    state.copyWith(
      mode: LooperMode.record,
      cursor: 0,
      activeBank: 0,
      excluded: const <int>{},
      parkedResume: const <int>{},
    ),
  );

  int get _channelCount =>
      ControlOverlayState.tracksPerBank * ControlOverlayState.bankCount;

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
