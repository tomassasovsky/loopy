# feat: session-fidelity hardening — fuzzer & docs — part 4/4

**Type:** enhancement (test/docs) · **Detail:** Standard · **Date:** 2026-07-11

> Part 4 of the [session overdub-layer-fidelity umbrella](2026-07-11-feat-session-overdub-layer-fidelity-plan.md).

## Dependencies

**Parts 1–3** (full save/restore of lanes + layers must exist to fuzz).

## Goal

Cross-cutting verification and cleanup, kept out of parts 1–3 the way the
control-state fuzzer (#108) and FX-state fuzzer (#112) shipped as their own PRs.

## Tasks

- [ ] **Round-trip property/fuzz test**, mirroring the existing control/FX-state
      fuzzers: random sequences of record / overdub / undo / redo / lane-add →
      `save` → `read` → `applySession` → assert full-state identity (per-layer PCM,
      `undoDepth`/`redoDepth`, per-lane mix/routing). Wire into CI.
- [ ] **`duplicateSession` safety test:** duplicate a bundle after a
      shrinking re-save, confirm no orphaned layer WAVs are copied (belt-and-suspenders
      on part 3's pruning).
- [ ] **Pool-cap guardrail:** part 2 already *rejects* over-`LE_POOL_SLOTS` imports;
      here surface it cleanly at the repository/bloc boundary (a typed failure /
      user-facing message on load) rather than a raw `StateError`. Drop the vague
      "telemetry" idea unless a concrete metric/consumer is named.
- [ ] **Docs:** `docs/design/` note on the v3 bundle format (cross-link the perf
      event-log format doc); remove the now-stale "multi-lane stems are a follow-up"
      comments in `engine_session.c`, `session_repository.dart`, `session_rig.dart`,
      and `looper_repository.dart`.

## Acceptance criteria

- [ ] Fuzz test green in CI over many randomized seeds.
- [ ] Over-cap load surfaces a typed, user-legible failure.
- [ ] No stale "lane-0 only / follow-up" comments remain; v3 format documented.
