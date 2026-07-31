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
/// - `binding/` is the optional pedal remap (part 6b): a pure-data binding
///   set, the sealed FX target it points at, and the resolution against the
///   live rig. It lives here — app-side, next to the one interpreter — so the
///   pedal/controller repository packages carry bindings as opaque strings
///   and gain no looper dependency, and no second control-surface interpreter
///   can grow inside a repository.
///
/// Design rationale:
/// docs/brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md.
library;

export 'binding/fx_binding_resolver.dart';
export 'binding/fx_binding_target.dart';
export 'binding/pedal_binding.dart';
export 'binding/pedal_binding_set.dart';
export 'control_projection.dart';
export 'cubit/control_cubit.dart';
export 'invariants.dart';
