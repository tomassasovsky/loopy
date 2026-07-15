---
title: "feat: performance recording — part 5: retired-layer persistence (D-LAYER)"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 5: retired-layer persistence (D-LAYER) — Standard

> **Split note:** part 5 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). Deliberately
> small — this is the **safety-critical correctness piece**, reviewed alone
> (precedent: the VST3 stack gave its cross-thread lifecycle its own PR).

## Overview

The verified hazard: `le_handle_retired`
([engine_commands.c:195–215](../../packages/loopy_engine/src/core/engine_commands.c))
silently drops a retired overdub layer when the track's undo stack is full;
`track_acquire_slot` (:41) evicts the oldest undo when the pool fills; clear
and redo-invalidation reclaim slots the same way. Audio that audibly played
can be destroyed before anything persists it — which would make the offline
render (part 7) silently wrong.

Fix (umbrella D-LAYER): while armed, **copy every retired layer's PCM into
drain-owned staging at `le_handle_retired` time**, then let the part 2 drain
thread persist staging to numbered raw files in the capture dir. All pool
bookkeeping (retire handling, eviction, clear, redo reclaim) runs **on the
control thread**, so the copy is naturally serialized against every reclaim
path — the pool machinery stays byte-for-byte untouched, no hold flag, no RT
change.

## Context / findings

- `le_handle_retired` runs during `le_engine_drain_events` (control thread,
  snapshot poll). The staging copy hooks there, gated on armed state.
- Staging → drain-thread hand-off is a simple SPSC of ready buffers (the
  only new cross-thread edge, control → drain).
- Cost: one memcpy of loop length (a few MB) per retired layer on the control
  thread — the same thread already does large memcpys for session save and
  will for the part 6 snapshots. Measure; if it ever matters, double-buffer.
- Layer files are named by track + retire frame (`layer-<t>-<frame>.pcm`) and
  recorded in the sidecar manifest so the renderer can stitch overdub passes
  (part 7).

## Acceptance Criteria

- [ ] **Layer survives pool eviction:** deliberately overflow
      `LE_POOL_SLOTS` with overdub passes while armed; every retired layer's
      PCM exists on disk with the correct retire frame (native test).
- [ ] **Clear during dub:** clearing a track mid-overdub while armed loses no
      already-retired layer; the in-flight pass follows the existing
      `dub_generation` semantics (native test).
- [ ] **Redo-invalidation:** undo → new overdub while armed persists the
      invalidated redo layers before their slots are reclaimed (native test).
- [ ] Staging hand-off ordering: a layer is never reported persisted before
      its file is flushed; drain-thread failure marks the sidecar, doesn't
      crash.
- [ ] Not armed → zero behavior change (regression: existing undo/redo/clear
      tests untouched and green).
- [ ] Native suite "ALL PASSED"; `flutter analyze` clean; format stable.

## Tasks

- [ ] `packages/loopy_engine/src/core/engine_commands.c` — armed-gated
      staging copy in `le_handle_retired` (+ the redo-invalidation and clear
      reclaim paths, which funnel through slot release — audit and cover).
- [ ] `packages/loopy_engine/src/core/perf_drain.c` — staging queue drain →
      `layer-<t>-<frame>.pcm` + sidecar manifest entries.
- [ ] Native tests: pool-overflow persistence, clear-during-dub,
      redo-invalidation, hand-off ordering, unarmed regression.

## Files touched (primary)

`packages/loopy_engine/src/core/{engine_commands.c,perf_drain.c,engine_private.h}`,
`packages/loopy_engine/src/test/test_engine_core.c`.

## Verification

1. `bash packages/loopy_engine/src/test/run_native_tests.sh` — "ALL PASSED".
2. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.

## Dependencies

- **Part 2** (drain thread), **Part 3** (retire events carry capture frames).
