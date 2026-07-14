---
title: "feat(vst3): golden-parity audio-diff harness (part 4)"
type: feat
date: 2026-07-08
part: 4 of 12
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 4 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> pilot.** Shared design (D-VALIDATE) lives in the umbrella. This is the
> feature's core correctness proof: an automated CI gate showing the VST3
> build is bit-exact (within float tolerance) with the live engine, not just
> "structurally similar."

## Dependencies

Parts 2, 3 (both plugin bundles must exist to diff against).

## Overview

The vendored VST3 SDK has **no** `validator` tool (confirmed: no
`samples/vst-hosting/validator` under the vendored tree) — spec-conformance
testing isn't available out of the box, so this part builds the thing that
actually matters for this feature's value proposition: proof that routing
audio through the built `.vst3` produces the **same samples** as calling
`fx_apply_chain` directly.

A small, headless VST3-hosting test harness (not a DAW, not the existing
third-party `IPluginHost`/`slot.cpp` hosting stack — that stack's contract is
explicitly "best effort," the wrong tool for a precision-parity test) loads
each built plugin via the SDK's `IPluginFactory`, feeds it a fixed test
signal (silence→impulse→sweep→noise, covering both steady-state and
transient behavior) across a representative parameter sweep, and captures
its output. The same signal is rendered directly through `engine_fx.c`'s
`fx_apply_chain` (same seam parts 2/3 use, called directly rather than
through the plugin). The two output buffers are diffed to a float tolerance,
matching the golden-parity testing precedent already established in this
codebase (`perf_render.c`'s master-parity test) rather than inventing a new
methodology.

## Tasks

- [ ] New test harness `packages/loopy_engine/vst3/test/host_harness.cpp` (or
  similar): a minimal, VST3-factory-driven loader — `GetPluginFactory()` →
  `createInstance` → `IComponent::initialize`/`setActive` →
  `IAudioProcessor::process` — no windowing, no editor, no scanning.
- [ ] Fixed test-signal generator (silence, unit impulse, log sweep, white
  noise) at a small set of representative sample rates/block sizes.
- [ ] Param-sweep matrix per effect: for Delay, a few (time, feedback, mix)
  combinations spanning the plain range; for Reverb, a few (size, damping,
  mix) combinations, including edges (min/max) and the documented default.
- [ ] Diff routine comparing the harness's VST3-hosted output against a
  direct `fx_apply_chain` call over the identical input/params, asserting
  within a float tolerance (reuse the tolerance-and-settle-window
  methodology from the existing golden master-parity test rather than
  picking a new number ad hoc).
- [ ] Wire as a new suite registered in the existing
  `run_native_tests.sh`-driven harness, so it's part of the standard native
  test gate, not a separate manual step.
- [ ] Document in the harness's header comment *why* the existing
  `IPluginHost` hosting stack isn't reused here (precision-diff test vs.
  "best effort" runtime contract — different jobs).

## File References

- New: `packages/loopy_engine/vst3/test/host_harness.cpp` (+ fixtures)
- [core/engine_fx.h](../../packages/loopy_engine/src/core/engine_fx.h) (direct-call comparison path)
- [core/perf_render.c](../../packages/loopy_engine/src/core/perf_render.c) (tolerance/settle-window methodology precedent)
- [test/run_native_tests.sh](../../packages/loopy_engine/src/test/run_native_tests.sh) (gate)
- `packages/loopy_engine/vst3/delay/`, `.../reverb/` (built artifacts under test, from parts 2/3)

## Acceptance Criteria

- [ ] The parity suite runs as part of `bash
  packages/loopy_engine/src/test/run_native_tests.sh` and passes for both
  Delay and Reverb across the full param-sweep matrix.
- [ ] A deliberately-introduced divergence (e.g. a mis-wired param mapping in
  a scratch branch) is caught by the suite — proven once during development,
  not just asserted.
- [ ] The suite runs headless in CI with no DAW, no GUI, no user interaction.

## Out of Scope

daw_export wiring (part 5); manual real-DAW checks (still required per
D-VALIDATE, but tracked in parts 2/3/8/9, not here — this part is the
*automated* half of D-VALIDATE only).
</content>
