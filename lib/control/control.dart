/// The control-surface spec: the invariant list every surface (pedal LEDs,
/// armed set, cursor, ring) must satisfy against engine truth. Enforced by
/// the sequence fuzzer (test/fuzz/) and by debug-mode asserts at projection
/// time. The phase-2 projection refactor (see
/// docs/plan/2026-07-04-refactor-control-state-robustness-plan.md) adds the
/// shared control overlay + pure projections here.
library;

export 'invariants.dart';
