/// The control layer: loopy's ONE home for stored user intent and its
/// derivations.
///
/// - `ControlCubit` (business logic layer) owns the closed stored-intent
///   inventory (mode, cursor, bank, excluded, parkedResume) — the only
///   control state that is not derivable from engine truth, each bit with a
///   written invalidation rule — AND is the one interpreter every surface
///   reaches: the pedal's decoded footswitches arrive through
///   `PedalRepository.events`, the keyboard and on-screen widgets call the
///   same methods, so command sequences can never diverge. Repositories are
///   composed at the bloc level (no domain-service orphans, no cubit
///   depending on another cubit).
/// - `control_projection.dart` computes everything else (armed set, LEDs,
///   the pedal frame) as pure functions of `(LooperState × overlay)` —
///   derived state cannot go stale.
/// - `invariants.dart` is the executable spec, enforced by the sequence
///   fuzzer (test/fuzz/) and by debug asserts on every projection.
///
/// Design rationale:
/// docs/brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md.
library;

export 'control_projection.dart';
export 'cubit/control_cubit.dart';
export 'invariants.dart';
