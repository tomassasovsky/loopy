---
title: "feat: performance recording — part 8: wet pass + golden master parity"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 8: wet pass + golden master parity — Standard

> **Split note:** part 8 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). Part 7 proved
> the replay timeline; this part proves **DSP parity**: the wet stem pass
> through `fx_apply_chain`, the master reconstruction, and the golden test
> that is this feature's correctness guardrail.

## Overview

Extend the part 7 renderer with a **wet pass** — FX chains applied per the
log (types/params from the arm snapshot, deltas replayed from logged events)
via the engine's own `fx_apply_chain`
([engine_fx.c:978](../../packages/loopy_engine/src/core/engine_fx.c)) — and a
**master reconstruction** (track sum + master gain + limiter, from the
snapshot's settings) that exists to power the golden parity gate. Stems land
in `stems/wet/`.

## Context / findings

- **`LE_FX_PLUGIN` slots render as dry passthrough in both passes**
  (umbrella D-RENDER): `fx_apply_chain` forwards plugin slots to a live
  hosted instance the renderer cannot share; offline plugin instantiation is
  a named follow-up, not an implicit consequence of "reuse the chain". The
  passthrough is recorded in the manifest (part 10 surfaces it in
  `fx-chains.txt`), and plugin-bearing chains are excluded from the parity
  scenario.
- **Golden parity protocol (fixed):** arm from silence, **no monitor
  inputs, no plugin slots**, scripted performance, compare the offline-
  reconstructed master against the live-captured master within float
  tolerance after a settle window. Pre-arm FX tails (delay/reverb state) and
  the limiter's smoothed `lim_gain` cannot be snapshotted — the protocol
  excludes them **by construction**, not by widening the tolerance.
- The raw (uncoalesced) event log from part 3 is what makes this test
  meaningful: every volume/param command replays at its exact frame.
- Stateful FX (delay lines, reverb combs, octaver heaps) allocate their DSP
  state renderer-side per lane, mirroring `le_fx_state` sizing at the
  snapshot sample rate.

## Acceptance Criteria

- [ ] Wet stems apply the logged FX chains; a chain with a mid-performance
      param sweep renders the sweep at the logged frames (native test).
- [ ] Plugin slot in a chain → wet stem passes through dry at that slot;
      manifest records the passthrough (native test).
- [ ] **Golden parity:** under the fixed protocol, the offline master matches
      the captured master within the declared float tolerance for a scripted
      multi-track performance with overdubs, mutes, volume rides, and FX
      sweeps (native test — the hard gate).
- [ ] Dry pass output from part 7 is unchanged (regression).
- [ ] `stems/wet/` assembled by `performance_repository`; partial-success
      posture preserved.
- [ ] Native suite "ALL PASSED"; `flutter analyze` clean; format stable.

## Tasks

- [ ] `packages/loopy_engine/src/core/perf_render.c` — wet pass (per-lane
      `le_fx_state` allocation, chain application per log, plugin
      passthrough), master reconstruction (sum + gain + limiter from
      snapshot).
- [ ] Golden parity native test: scripted performance driver (reuses the
      part 1 capture path live, then renders offline, then compares), settle
      window + tolerance constants documented next to the test.
- [ ] `performance_repository` — `stems/wet/` in bundle assembly + manifest
      passthrough notes.
- [ ] Native tests: sweep-in-wet-stem, plugin passthrough, parity gate, dry
      regression.

## Files touched (primary)

`packages/loopy_engine/src/core/perf_render.c`,
`packages/loopy_engine/src/test/test_engine_core.c`,
`packages/performance_repository/lib/src/*`.

## Verification

1. `bash packages/loopy_engine/src/test/run_native_tests.sh` — "ALL PASSED"
   (includes the parity gate).
2. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
3. `flutter test packages/performance_repository`.

## Dependencies

- **Part 7** (renderer core).
