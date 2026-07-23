part of 'control_cubit.dart';

/// The CLOSED inventory of stored user intent — the only control-surface
/// state that is not derivable from a `LooperState` snapshot. Everything else
/// (the armed set, every LED, the ring) is a pure function of
/// `(LooperState × ControlState)` — see `control_projection.dart`.
///
/// Every field here has a written invalidation rule (the table in
/// docs/brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md),
/// implemented in ONE place: [ControlCubit]'s looper reducer plus the
/// explicit intent methods. Nothing else may store control state.
class ControlState extends Equatable {
  /// Creates a [ControlState].
  const ControlState({
    this.mode = InteractionMode.record,
    this.defaultMode = InteractionMode.record,
    this.cursor = 0,
    this.activeBank = 0,
    this.excluded = const <int>{},
    this.parkedResume = const <int>{},
  });

  /// Tracks per bank.
  static const int tracksPerBank = 4;

  /// The number of banks.
  static const int bankCount = 2;

  /// The system-wide record/mute mode — every surface (pedal footswitch, `M`
  /// key, on-screen chip) toggles and reads this ONE field. Changed only by
  /// explicit mode actions (clear-all counts: a whole-rig reset → record).
  final InteractionMode mode;

  /// The persisted mode the system boots into.
  final InteractionMode defaultMode;

  /// The ONE track cursor, shared by every surface (`0..7`). Rec-mode
  /// Rec/Play, Stop, Undo and Redo target it. Clamped to a valid channel by
  /// the looper reducer; reset by clear-all.
  final int cursor;

  /// The visible bank (`0` = A, `1` = B). A stored bit: bank BROWSE without
  /// moving the cursor is a real flow (arming the other bank's tracks in mute
  /// mode). Any cursor write also sets `bank = cursor ~/ 4`, so the cursor
  /// can never hide behind the other bank.
  final int activeBank;

  /// Mute-mode opt-outs: tracks the user deliberately pulled out of the mix.
  /// A sounding track outside this set is ALWAYS armed —
  /// `armed = sounding ∖ excluded` — so redo / an on-screen play re-enters
  /// the mix with no reconciliation. Cleared when the track empties, on
  /// clear-all, on mode entry, and on session load. (No surface writes it
  /// yet: the pedal's mute-mode track press mutes rather than excludes; the
  /// representation exists so a future disarm affordance cannot re-create
  /// the stale-armed-set bug class.)
  final Set<int> excluded;

  /// What Rec/Play resumes while parked: latched at PARK-INTENT time from the
  /// then-derived armed set (Stop-park), set to ∅ by mute-last-track park
  /// (Rec/Play then falls back to ALL content), and set to all content tracks
  /// on mode entry into Mute. Members drop when their track empties; cleared
  /// on clear-all, mode entry, session load, and consumed by the next resume.
  final Set<int> parkedResume;

  /// The first channel of the visible bank (`0` for A, `4` for B).
  int get bankBaseChannel => activeBank * tracksPerBank;

  /// Whether [channel] falls within the visible bank.
  bool bankContains(int channel) =>
      channel >= bankBaseChannel && channel < bankBaseChannel + tracksPerBank;

  /// Returns a copy with the given fields replaced.
  ControlState copyWith({
    InteractionMode? mode,
    InteractionMode? defaultMode,
    int? cursor,
    int? activeBank,
    Set<int>? excluded,
    Set<int>? parkedResume,
  }) => ControlState(
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
