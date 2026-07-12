# feat: overdub-layer export/import — engine only (C) — part 2/4

**Type:** enhancement (engine) · **Detail:** Extensive · **Date:** 2026-07-11

> Part 2 of the [session overdub-layer-fidelity umbrella](2026-07-11-feat-session-overdub-layer-fidelity-plan.md).

## Dependencies

**Part 1** (for manifest/DTO context only — this PR ships **no Dart changes**, so
there is no code dependency; sequence after part 1 to keep review focus narrow).

## Goal

Give the C engine the ability to **export every overdub layer** of a track and to
**rebuild a track's full pool + undo/redo stacks** on import — proven end-to-end
by a C round-trip harness, entirely without FFI/Dart. Part 3 wires it to Dart.

## Background — the layer model (verified)

- An overdub layer is a **full pre-pass image** of the loop, stored in a lane
  `pool[]` slot ([engine_private.h:255](packages/loopy_engine/src/core/engine_private.h#L255)).
  A lane's complete state is the ordered buffer set
  `undo_stack[0..undo_count)` → `a_live` → `redo_stack[0..redo_count)`.
- The undo/redo stacks are **track-owned and shared across lanes in lockstep** —
  the same pool slot index names the snapshot in every lane
  ([engine_private.h:247](packages/loopy_engine/src/core/engine_private.h#L247)).
- `undo_count`/`redo_count` are already published as `a_undo_depth`/`a_redo_depth`
  ([:313](packages/loopy_engine/src/core/engine_private.h#L313)) — **no new
  count-query FFI is needed** (part 3's Dart side reads them off the snapshot).
- `LE_POOL_SLOTS == 256` ([:57](packages/loopy_engine/src/core/engine_private.h#L57))
  caps total layers; live rigs evict the oldest past the cap.

## Design — symmetric export/import (no monolithic struct)

Export and import are decomposed identically, one call per layer, mirroring the
per-file WAV loop part 3's Dart side will run — avoids marshaling a nested
lanes→layers→PCM FFI struct.

### Export

- [ ] `le_engine_export_layer(channel, lane, ordinal, out, max_frames)` where
      `ordinal` walks `undo_stack[0..undo_count)` → `a_live` →
      `redo_stack[0..redo_count)`. Copies that pool slot's buffer + returns its
      frame count. Control-thread only; track not capturing (same safety as
      [`le_engine_export_track_lane`](packages/loopy_engine/src/core/engine_session.c#L37)).
      Caller learns the ordinal range from the existing `a_undo_depth`/`a_redo_depth`.

### Import (scratch-build, atomic publish — R4)

- [ ] `le_engine_import_layer(channel, lane, ordinal, pcm, frames)` — stage one
      layer buffer into a per-track **scratch** reconstruction of the pool (into an
      EMPTY track; never mutate a published track mid-rebuild).
- [ ] `le_engine_finalize_layers(channel, undo_count, redo_count)` — once all
      layers of all lanes are staged, publish atomically: assign pool slots, set
      each lane's `a_live` to the live buffer, populate `undo_stack`/`redo_stack`
      with the slot indices **in lockstep across lanes**, set
      `a_undo_depth`/`a_redo_depth`, `a_len`, and `lane_count`. Pairs with
      `le_engine_commit_session` to establish the master.
- [ ] **R1 cap:** reject (`LE_ERR_INVALID`) when `undo_count + 1 + redo_count`
      exceeds `LE_POOL_SLOTS`, or a layer exceeds `max_loop_frames` — fail loudly,
      leave the track EMPTY. Do not silently clamp/overflow the stack arrays.
- [ ] **Atomicity:** a mid-rebuild failure (bad frame count, slot-alloc failure)
      leaves the track EMPTY — build into scratch, publish only on full success.

### C round-trip harness (the contract proof)

- [ ] Record K overdub passes across M lanes → for each `(lane, ordinal)`
      `export_layer` → import into a **fresh** engine via `import_layer` +
      `finalize_layers` + `commit_session` → assert:
  - live PCM identity per lane;
  - `a_undo_depth`/`a_redo_depth` match the source;
  - `undo` K times reproduces each pre-pass image per lane (lockstep);
  - `redo` restores.
- [ ] Cap test: importing `> LE_POOL_SLOTS` layers is rejected and leaves EMPTY.
- [ ] Zero-undo track (recorded, never overdubbed) → one live layer, `undo == 0`.
- [ ] Undone-into-the-past track (`a_live` != newest) → `redo_count > 0` preserved.

## Acceptance criteria

- [ ] Full layer + undo/redo state round-trips through export→import **in C**, with
      byte-identical per-layer PCM and matching stack depths.
- [ ] Undo/redo replay reproduces every take after a rebuild-import.
- [ ] Over-cap and oversized-layer imports are rejected, leaving the track EMPTY.
- [ ] No FFI/Dart files change in this PR; all existing engine tests pass.

## Stacked-PR note

Do not `--delete-branch` on merge — parts 3–4 stack on this. After part 1 merges,
merge `master` into this branch to catch up before continuing review.
