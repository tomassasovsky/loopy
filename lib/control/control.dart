/// The control layer: loopy's ONE home for stored user intent and its
/// derivations.
///
/// - `ControlOverlay` (a DOMAIN store, not a cubit) owns the closed
///   stored-intent inventory (mode, cursor, bank, excluded, parkedResume) —
///   the only control state that is not derivable from engine truth, each
///   bit with a written invalidation rule.
/// - `ControlIntents` is the one interpreter every surface reaches (the
///   pedal via `PedalCubit`'s decode, the keyboard and on-screen widgets via
///   `ControlOverlayCubit`'s delegating actions), so command sequences can
///   never diverge. Widgets never touch the domain layer directly, and no
///   cubit depends on another cubit — both connect through the store.
/// - `control_projection.dart` computes everything else (armed set, LEDs,
///   the pedal frame) as pure functions of `(LooperState × overlay)` —
///   derived state cannot go stale.
/// - `invariants.dart` is the executable spec, enforced by the sequence
///   fuzzer (test/fuzz/) and by debug asserts on every projection.
///
/// Design rationale:
/// docs/brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md.
library;

export 'control_intents.dart';
export 'control_overlay.dart';
export 'control_projection.dart';
export 'cubit/control_overlay_cubit.dart';
export 'invariants.dart';
