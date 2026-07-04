import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/model/looper_mode.dart';

/// The CLOSED inventory of stored user intent — the only control-surface
/// state that is not derivable from a `LooperState` snapshot. Everything else
/// (the armed set, every LED, the ring) is a pure function of
/// `(LooperState × ControlOverlayState)` — see `control_projection.dart`.
///
/// Every field here has a written invalidation rule (the table in
/// docs/brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md),
/// implemented in ONE place: [ControlOverlay]'s looper reducer plus the
/// explicit intent methods. Nothing else may store control state.
class ControlOverlayState extends Equatable {
  /// Creates a [ControlOverlayState].
  const ControlOverlayState({
    this.mode = LooperMode.record,
    this.defaultMode = LooperMode.record,
    this.cursor = 0,
    this.activeBank = 0,
    this.excluded = const <int>{},
    this.parkedResume = const <int>{},
  });

  /// Tracks per bank.
  static const int tracksPerBank = 4;

  /// The number of banks.
  static const int bankCount = 2;

  /// The system-wide record/play mode — every surface (pedal footswitch, `M`
  /// key, on-screen chip) toggles and reads this ONE field. Changed only by
  /// explicit mode actions (clear-all counts: a whole-rig reset → record).
  final LooperMode mode;

  /// The persisted mode the system boots into.
  final LooperMode defaultMode;

  /// The ONE track cursor, shared by every surface (`0..7`). Rec-mode
  /// Rec/Play, Stop, Undo and Redo target it. Clamped to a valid channel by
  /// the looper reducer; reset by clear-all.
  final int cursor;

  /// The visible bank (`0` = A, `1` = B). A stored bit: bank BROWSE without
  /// moving the cursor is a real flow (arming the other bank's tracks in play
  /// mode). Any cursor write also sets `bank = cursor ~/ 4`, so the cursor
  /// can never hide behind the other bank.
  final int activeBank;

  /// Play-mode opt-outs: tracks the user deliberately pulled out of the mix.
  /// A sounding track outside this set is ALWAYS armed —
  /// `armed = sounding ∖ excluded` — so redo / an on-screen play re-enters
  /// the mix with no reconciliation. Cleared when the track empties, on
  /// clear-all, on mode entry, and on session load. (No surface writes it
  /// yet: the pedal's play-mode track press mutes rather than excludes; the
  /// representation exists so a future disarm affordance cannot re-create
  /// the stale-armed-set bug class.)
  final Set<int> excluded;

  /// What Rec/Play resumes while parked: latched at PARK-INTENT time from the
  /// then-derived armed set (Stop-park), set to ∅ by mute-last-track park
  /// (Rec/Play then falls back to ALL content), and set to all content tracks
  /// on mode entry into Play. Members drop when their track empties; cleared
  /// on clear-all, mode entry, session load, and consumed by the next resume.
  final Set<int> parkedResume;

  /// The first channel of the visible bank (`0` for A, `4` for B).
  int get bankBaseChannel => activeBank * tracksPerBank;

  /// Whether [channel] falls within the visible bank.
  bool bankContains(int channel) =>
      channel >= bankBaseChannel && channel < bankBaseChannel + tracksPerBank;

  /// Returns a copy with the given fields replaced.
  ControlOverlayState copyWith({
    LooperMode? mode,
    LooperMode? defaultMode,
    int? cursor,
    int? activeBank,
    Set<int>? excluded,
    Set<int>? parkedResume,
  }) => ControlOverlayState(
    mode: mode ?? this.mode,
    defaultMode: defaultMode ?? this.defaultMode,
    cursor: cursor ?? this.cursor,
    activeBank: activeBank ?? this.activeBank,
    excluded: excluded ?? this.excluded,
    parkedResume: parkedResume ?? this.parkedResume,
  );

  @override
  List<Object?> get props => [
    mode,
    defaultMode,
    cursor,
    activeBank,
    excluded,
    parkedResume,
  ];
}

/// The DOMAIN store owning [ControlOverlayState] — a plain class with a
/// state and a change stream, deliberately NOT a cubit: cubits must never
/// depend on other cubits (bloc-to-bloc communication), so the shared
/// overlay lives at the domain layer where `ControlIntents`, `PedalCubit`,
/// and the presentation mirror (`ControlOverlayCubit`) can all depend on it
/// the same way they depend on repositories.
///
/// State flows IN through this store's own subscription to
/// `LooperRepository.looperState`: the [_reduce] reducer applies the
/// invalidation table on every snapshot (cursor clamps; excluded/parkedResume
/// members drop when their track empties — which also covers clear-all and
/// session load, since those empty the tracks). Commands flow OUT through
/// `ControlIntents`, never from here — the overlay holds no command-issuing
/// repository call, so it can never become a second command path.
///
/// Derived state (the armed set, LEDs, the ring) is computed from
/// `(LooperState × ControlOverlayState)` by the pure functions in
/// `control_projection.dart`; nothing derived is ever stored.
class ControlOverlay {
  /// Creates a [ControlOverlay] reducing over [looper]'s state stream.
  ControlOverlay({required LooperRepository looper}) {
    _sub = looper.looperState.listen(_reduce);
  }

  ControlOverlayState _state = const ControlOverlayState();
  // Plain synchronous callbacks, deliberately NOT a stream: a mutation must
  // notify listeners (the mirror cubit, the pedal's frame push) in the SAME
  // turn, in the CALLER's zone. A stream pins delivery to the zone its
  // subscription was created in, which detaches notifications from the
  // caller (visible as widget tests whose watchers never rebuild). Safe:
  // no listener mutates the store back (the mirror only re-emits, the pedal
  // only projects), so synchronous delivery cannot re-enter [_emit].
  final List<void Function(ControlOverlayState state)> _listeners = [];
  late final StreamSubscription<LooperState> _sub;
  bool _disposed = false;

  /// The current stored intent.
  ControlOverlayState get state => _state;

  /// Registers [listener], called synchronously after every state change
  /// (deduplicated — no-op writes are silent).
  void addListener(void Function(ControlOverlayState state) listener) =>
      _listeners.add(listener);

  /// Unregisters a previously added [listener].
  void removeListener(void Function(ControlOverlayState state) listener) =>
      _listeners.remove(listener);

  void _emit(ControlOverlayState next) {
    if (next == _state || _disposed) return;
    _state = next;
    for (final listener in List.of(_listeners)) {
      listener(next);
    }
  }

  /// The one reducer over engine truth: every stored bit's snapshot-driven
  /// invalidation rule lives HERE and nowhere else.
  void _reduce(LooperState looper) {
    var next = _state;

    // Cursor: always a valid channel.
    if (looper.tracks.isNotEmpty &&
        (_state.cursor < 0 || _state.cursor >= looper.tracks.length)) {
      final cursor = _state.cursor.clamp(0, looper.tracks.length - 1);
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

    if (_state.excluded.any((c) => !playable(c))) {
      next = next.copyWith(excluded: _state.excluded.where(playable).toSet());
    }
    if (_state.parkedResume.any((c) => !playable(c))) {
      next = next.copyWith(
        parkedResume: _state.parkedResume.where(playable).toSet(),
      );
    }

    _emit(next);
  }

  /// Moves the cursor to [channel], following it into its bank (a cursor can
  /// never hide behind the other bank). The one selection every surface
  /// shares.
  void selectTrack(int channel) {
    if (channel < 0 || channel >= _channelCount) return;
    _emit(
      _state.copyWith(
        cursor: channel,
        activeBank: channel ~/ ControlOverlayState.tracksPerBank,
      ),
    );
  }

  /// Reveals [bank] WITHOUT moving the cursor — the browse flow (e.g. arming
  /// the other bank's tracks in play mode).
  void browseBank(int bank) {
    if (bank < 0 || bank >= ControlOverlayState.bankCount) return;
    _emit(_state.copyWith(activeBank: bank));
  }

  /// Applies a mode change plus its stored-intent invalidations. The
  /// TRANSPORT side effects of a mode entry (finalizing captures) belong to
  /// `ControlIntents`, which calls this after issuing them.
  void applyMode(LooperMode mode, {required Set<int> parkedResume}) => _emit(
    _state.copyWith(
      mode: mode,
      excluded: const <int>{},
      parkedResume: parkedResume,
    ),
  );

  /// Records the persisted boot-default mode.
  void setDefaultMode(LooperMode mode) =>
      _emit(_state.copyWith(defaultMode: mode));

  /// Latches what Rec/Play resumes while parked (park-intent time — engine
  /// truth lags the stop commands by a poll, so latching from a later
  /// snapshot would always capture the empty set).
  void latchParkedResume(Set<int> channels) =>
      _emit(_state.copyWith(parkedResume: channels));

  /// Toggles [channel]'s membership of the parked-resume set (the play-mode
  /// track press while parked).
  void toggleParkedResume(int channel) {
    final next = {..._state.parkedResume};
    if (!next.remove(channel)) next.add(channel);
    _emit(_state.copyWith(parkedResume: next));
  }

  /// Removes [channel] from the deliberate play-mode exclusions — joining the
  /// mix is the explicit un-exclude.
  void include(int channel) {
    if (!_state.excluded.contains(channel)) return;
    _emit(_state.copyWith(excluded: {..._state.excluded}..remove(channel)));
  }

  /// The whole-rig reset (clear-all is an explicit mode action): record mode,
  /// cursor home, no stored play intent — unified across every surface.
  void resetForClearAll() => _emit(
    _state.copyWith(
      mode: LooperMode.record,
      cursor: 0,
      activeBank: 0,
      excluded: const <int>{},
      parkedResume: const <int>{},
    ),
  );

  int get _channelCount =>
      ControlOverlayState.tracksPerBank * ControlOverlayState.bankCount;

  /// Cancels the looper subscription and drops all listeners.
  Future<void> dispose() async {
    _disposed = true;
    _listeners.clear();
    await _sub.cancel();
  }
}
