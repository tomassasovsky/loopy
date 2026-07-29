---
title: "feat(engine): loop-stage wet cache with live fallback"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Fable at extra-high effort · `autonomy:merge-gate` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Give the Loop stage a background-rendered wet cache: when a lane's chain is
stable, a worker thread renders the loop's wet result offline and the audio
thread plays the cached stereo buffer at zero FX CPU; any edit falls back to
live processing the same frame and re-renders. The design rule is "when in
doubt, play live" — the cache is invisible, never destructive, and never
allowed to play stale audio. This part is engine-native only (one PR), plus
the ffigen surface for the cache cap and telemetry.

## Dependencies

Must be merged first:

- `2026-07-28-feat-fx-system-v3-part-1a-plan.md` — universal bypass
  (per-slot `a_fx_enabled[LE_FX_MAX]` + per-chain `a_fx_chain_enabled`,
  click-free crossfade ramp in `fx_apply_chain`, enabled bits folded into the
  chain fingerprint, plog enabled events, `snapshot_track_fx` →
  `snapshot_lane_fx` rename).
- `2026-07-28-feat-fx-system-v3-part-1b-plan.md` — track stereo bus +
  Track/Master inserts (D-MASTER / D-TRACKROUTE / D-MASTERCH pinned).

Part 2 consumes from part 1: the enabled-aware `fx_apply_chain` signature,
the fingerprint family that folds params + enabled bits
(`engine_snapshot.c:102-138`, `le_engine_lane_fx_fingerprint`), and the
convention that heap allocations for FX owners happen on the control thread.

## Context

Key files (all under `packages/loopy_engine/` unless noted):

- `src/core/engine_private.h` — lane/track owner structs; **pool slots
  recycle** (`engine_private.h:95-100`, `LE_POOL_SLOTS` with slot
  recycling past the cap), which is why the slot index can never key the
  cache [R1]. New atomics and cache structs land here.
- `src/core/engine_process.c` — audio callback; lane volume applies
  **PRE-chain** at `engine_process.c:3432` (`a_vol_bits`), which forces
  D-VOL below. Cache swap-in / fallback branch lives in the lane mix path.
- `src/core/engine_fx.c` — `fx_apply_chain` vtable DSP +
  `le_fx_entry_reset`; the worker reuses this DSP verbatim on a heap
  `le_fx_state`.
- `src/core/perf_render.c` — the offline-chain **pattern only**: it reads a
  finalized on-disk capture, so the cache renderer does NOT inherit its
  safety for free [R2]; the threading contract below exists because the
  cache renders from live pool memory.
- `src/core/engine_plugin.c` — the clear-slot reclamation pattern (retract →
  two processed-buffer boundaries via `a_frames` → free) and the
  `fx->plugin[]` atomic-publication discipline the cache mirrors [R2].
- `src/core/engine_commands.c`, `src/core/loopy_engine_api.h` — API + ring
  command surface for the cache cap and telemetry.
- `src/core/engine_snapshot.c` — per-buffer snapshot; gains per-lane cache
  state telemetry (log/test-only in v3).
- `src/test/test_engine_core.c` + `src/test/run_native_tests.sh` — the merge
  gate. The runner globs `src/core/engine*.c`, so a new `engine_*.c` TU is
  picked up automatically — but `src/CMakeLists.txt`'s `add_library` list
  must be updated in the same commit (the runner header demands they stay in
  sync). `EXTRA_CFLAGS="-fsanitize=address -g"` is the documented ASan hook.
- Dart mirror: `lib/src/fx_fingerprint.dart` +
  `packages/looper_repository/test/fx_fingerprint_agreement_test.dart` — the
  cache **key** composes {revision, fingerprint, `a_vol_bits`} natively; the
  chain fingerprint itself is unchanged by this part, so the Dart mirror
  should need no change (verify the agreement test stays green regardless).

Pinned decisions lifted from the index (do not reopen):

- **[R1] content revision, not slot identity:** per-track
  `_Atomic uint32_t a_audio_rev` keys "which audio", with an audited
  bump-site table spanning both threads. The pool slot index can never key
  the cache (slots recycle, `engine_private.h:95-100`).
- **D-VOL [R1]:** lane volume is applied pre-chain and drive/octaver are
  nonlinear, so `a_vol_bits` folds into the cache key and the render
  debounce extends to volume moves. Unity-render + post-volume for
  linear-only chains is explicitly future work, not v3.
- **[R2] worker threading contract:** copy-at-enqueue dry PCM, atomic
  publication mirroring `fx->plugin[]`, quiescent reclamation via the
  `engine_plugin.c` clear-slot pattern, worker joined before any free in
  stop/configure/destroy, ASan destroy-during-active-render test.
- **[B6]** single worker, playing-lanes-first priority.
- **[R5]** cache entries are stereo (chains decorrelate); memory accounting
  is 2× frames. Mute during cached playback routes nothing; unmute stays
  cached (tails are part of the periodic render — a small documented
  difference from live).
- **[B2][B3]** toggled-pair retention + ~250 ms settle debounce.
- **[B4]** fallback resets DSP state; tails drop at the edit instant —
  accepted, documented, listen-checked.
- **[B5]** mid-render invalidation: discard unless the key still matches at
  completion; the worker aborts on an `a_audio_rev` bump.
- **Plugin-bearing chains are never cached** (offline render would pass
  plugins dry); telemetry states why.
- Telemetry is **log/test-only in v3**; the lane-card debug glyph is part 9
  [R27].

Risks (lifted from the index risk table, scoped to this part):

| Risk | Mitigation |
|------|------------|
| Cache plays stale/wrong audio | Key = revision + fingerprint(params, enabled) + volume; audited bump-site table [R1]; "in doubt → live"; storm + overdub tests; telemetry |
| Render worker races the audio thread | Copy-at-enqueue + atomic publish + quiescent reclaim + join-before-free, ASan test [R2] |
| Cache churn under stomping / sweeps | Toggled-pair retention + settle debounce incl. volume [B2][B3][R1] |
| Memory blowup (stereo entries + in-flight copies) | 2× frames accounting, copies count against the cap, LRU eviction (evicted = live) |
| Squash-merge landmines on the stacked series | Per-part branch off part 1b's branch; rebase children after each squash-merge (see Notes) |

## Tasks

- [ ] **Content revision counter `a_audio_rev` [R1]**
  - Add per-track `_Atomic uint32_t a_audio_rev` (`engine_private.h`),
    bumped in lockstep with `a_live` swaps and content writes.
  - Write the **audited bump-site table spanning both threads** as a block
    comment next to the field declaration, with one row per site and the
    thread that performs it: record finalize; entry into OVERDUBBING **and**
    each retired overdub pass; undo swap; redo swap; redo-from-empty; clear;
    clear-restore (#219); session load. Every row cites the function that
    bumps. The table is the review artifact — an unaudited content write is
    a stale-audio bug by definition.
  - Document in the same comment why the pool slot index can never key the
    cache (slots recycle, `engine_private.h:95-100`).
- [ ] **Cache key + entry structs**
  - Key = {`a_audio_rev`, chain fingerprint including params + enabled bits
    (part 1), `a_vol_bits`} — **D-VOL**: volume is part of the wet recipe
    because it applies pre-chain (`engine_process.c:3432`) and drive/octaver
    are nonlinear [R1].
  - Entries are **stereo** float buffers [R5]; memory accounting = 2× frames
    per entry. Control-thread allocation per the existing FX-owner contract.
  - **Toggled-pair retention [B2]:** keep both entries of an
    enabled-bit-toggled pair alive so stomping an effect off/on is cache-hot
    in both directions; the pair counts twice against the cap.
- [ ] **Render worker + threading contract [R2]** — `perf_render` reads only
  a finalized on-disk capture; the cache renderer does NOT get that for
  free, so each clause below is explicit:
  - (a) **Dry-PCM handoff = copy-at-enqueue.** The control thread copies the
    lane's dry PCM into a worker-owned buffer at enqueue time, only while
    the track is not RECORDING/OVERDUBBING, tagged with the `a_audio_rev` it
    copied under. A finished render is discarded if the revision moved.
    In-flight copies count against the memory cap.
  - (b) **Wet-buffer publication mirrors the `fx->plugin[]` discipline:**
    control/worker-allocated, fully written, then published as one atomic
    pointer + key that the audio thread loads once per buffer. The audio
    thread never sees a partially-written entry.
  - (c) **Reclamation uses the `engine_plugin.c` clear-slot pattern:**
    retract the pointer → wait two processed-buffer boundaries observed via
    `a_frames` → free. No wet buffer is freed while the audio thread could
    still hold the previous load.
  - (d) **Join-before-free:** the worker is joined in `le_engine_stop`,
    `le_engine_configure`, and `le_engine_destroy` **before** any pool or
    wet-buffer free. Add the ASan destroy-during-active-render test (below).
- [ ] **Worker scheduling [B6]**
  - Single worker thread; queue ordered playing-lanes-first (a lane
    currently audible always renders before a stopped one).
  - Engine DSP reused **verbatim** on a heap `le_fx_state` per render — the
    `perf_render` pattern; no forked DSP.
  - **Render-twice-keep-second** for loop-wrapping tails: process the loop
    twice back-to-back through the chain, keep the second pass, so delay and
    reverb tails that wrap the loop boundary are baked in.
  - Worker aborts the in-progress render when it observes an `a_audio_rev`
    bump for its lane [B5].
- [ ] **Render debounce [B2][B3]**
  - No render is scheduled until the chain is stable for a settle window
    (~250 ms, one named constant).
  - Continuously-moving state — bound params (part 7's expression sweeps)
    and volume moves (D-VOL) — suppresses scheduling until it settles; the
    debounce timer resets on every key-affecting change.
- [ ] **Swap-in, fallback, and the documented tail-drop [B4]**
  - Cached playback engages only at the loop boundary (never mid-cycle), so
    cache-in is click-free by construction.
  - Any invalidation (param edit, enabled flip, volume move, content bump)
    → **immediate live fallback in the same frame**: the audio thread's
    per-buffer key check fails and it runs `fx_apply_chain` live.
  - **Documented behavior:** fallback resets DSP state via
    `le_fx_entry_reset`; effect tails drop at the edit instant. Accepted +
    listen-checked (A/B listen note in the PR) [B4].
  - Mute during cached playback routes nothing; unmute resumes cached
    playback (tails are part of the periodic render — small documented
    difference from live) [R5].
- [ ] **Mid-render invalidation [B5]**
  - A completed render is published only if its key still matches the lane's
    current key at completion; otherwise discarded.
  - Worker checks `a_audio_rev` periodically during the render and aborts
    early on a bump (cheap check per processed block, not per sample).
- [ ] **Plugin-chain exclusion**
  - A chain containing any plugin slot is never cached (the offline render
    would pass plugins dry); the lane stays live permanently and the
    telemetry state says why (distinct `gave-up`-class reason, not a silent
    live).
- [ ] **Memory cap + LRU eviction**
  - Configurable cap (engine API + ring command, appliance-tuned default);
    accounting covers stereo entries (2×), toggled pairs, and in-flight
    enqueue copies.
  - LRU eviction; an evicted lane simply plays live and may re-render later.
    Eviction never touches the entry currently published to the audio thread
    without the quiescent-reclaim dance.
- [ ] **Telemetry — log/test-only in v3 [R27]**
  - Per-lane cache state in the snapshot:
    `live | cached | rendering | failed-retrying | gave-up` (+ reason for
    gave-up, e.g. plugin-bearing). Exposed for tests and logs only; **no UI
    in this part** (debug glyph is part 9).
- [ ] **API surface + ffigen**
  - `loopy_engine_api.h`: cache cap setter, telemetry accessors (snapshot
    fields), anything the tests need. Ring commands in
    `engine_commands.c` where a heap pointer moves; direct atomic stores
    where not (the part-1 convention).
  - ffigen regen + `dart format` for the new native surface (cache cap,
    telemetry) — the regen emits short-style and churns the whole bindings
    file; `dart format` after regen is mandatory (documented in
    `ffigen.yaml`).
  - Keep `src/CMakeLists.txt`'s source list in sync if a new
    `engine_*.c` TU is added (the test runner globs; CMake does not).
- [ ] **Native tests (`test_engine_core.c`)** — all gate on
  `run_native_tests.sh`:
  - **Cached ≈ live** within float tolerance for every built-in effect type
    (render a loop, compare cached playback buffers against a live-processed
    reference per built-in).
  - **Volume move invalidates** (D-VOL): a volume change during cached
    playback falls back live and re-keys; the stale-volume entry never
    plays.
  - **Param edit → fallback within one buffer:** the first audio buffer
    after the edit is live-processed.
  - **Boundary swap continuity:** cache-in at the loop boundary produces no
    discontinuity versus the live signal (sample-compare across the seam).
  - **Overdub invalidates and never plays stale audio [A7]:** entering
    OVERDUBBING bumps `a_audio_rev`, playback is live for the whole overdub,
    and the retired pass re-keys; assert no buffer ever came from the
    pre-overdub entry.
  - **Toggle round-trip is cache-hot [B2]:** disable then re-enable an
    effect after both renders settle; both directions hit the retained pair
    with zero re-render.
  - **Eviction:** exceed the cap, assert LRU order, evicted lane plays live
    and re-renders on demand.
  - **Plugin exclusion:** a plugin-bearing chain reports the excluded
    telemetry state and never publishes an entry.
  - **Invalidation storm:** rapid param/enabled/volume churn across lanes —
    no crash, no stale publish, debounce holds renders off until settle,
    output remains live-correct throughout.
  - **ASan destroy-during-active-render [R2]:** start a render, call
    `le_engine_destroy` (and configure/stop variants) mid-render; run under
    `EXTRA_CFLAGS="-fsanitize=address -g"` — no use-after-free, no leak, no
    unjoined thread.
  - Bump-site audit test: drive each row of the [R1] table (record finalize,
    overdub entry + retired pass, undo, redo, redo-from-empty, clear,
    clear-restore, session load) and assert `a_audio_rev` changed.
- [ ] **PR hygiene**
  - One PR for the whole part, branched off part 1b's branch until 1b
    merges, then rebased onto `master`.
  - Child issue under #351 with `stage:*` + `autonomy:*` labels per
    `docs/TRACKING.md`; PR body carries `Closes #<child>` and
    `Part of #351`; gate labels `ci:*` + `review:pending`.
  - A/B listen note on desktop recorded in the PR (the [B4] tail-drop and
    cached-vs-live parity are listen-checked, not only float-compared).

## Success Criteria

```success-criteria
GOAL: Loop-stage wet results render in the background and play at zero FX CPU, with same-frame live fallback on any edit — cached audio is correct (volume-in-key), never stale (audited revision bumps), and the worker lifecycle is sanitizer-clean.

SUCCESS CRITERIA:
- a_audio_rev exists with the audited bump-site table [R1] and every table row is exercised by a native test (record finalize, overdub entry + retired pass, undo/redo, redo-from-empty, clear + clear-restore, session load) | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Cached playback ≈ live within float tolerance for every built-in, with a_vol_bits in the key (D-VOL): volume move invalidates and re-keys | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Any edit falls back live within one buffer; boundary swap-in is continuity-clean; documented tail-drop on fallback [B4] | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Overdub invalidates and never plays stale audio [A7]; invalidation storm is crash-free and stale-free with the settle debounce holding [B2][B3][B5] | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Toggled-pair retention makes off/on stomps cache-hot [B2]; LRU eviction degrades to live; plugin-bearing chains are excluded with telemetry stating why | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Worker lifecycle clean under ASan: copy-at-enqueue, atomic publish, quiescent reclaim, join-before-free incl. destroy-during-active-render [R2] | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/loopy_engine/src/test/run_native_tests.sh
- Dart bindings regenerated + formatted for the new surface (cache cap, telemetry); engine package suite and the fingerprint agreement test stay green | verify: /Users/Tomas/development/flutter/bin/flutter test packages/loopy_engine packages/looper_repository/test/fx_fingerprint_agreement_test.dart

NON-GOALS:
- Bypass, track bus, Track/Master inserts — parts 1a/1b own those (merged prerequisites here)
- Caching the Input, Track, or Master stages, or plugin-bearing chains (explicit exclusion)
- Dart domain model enabled/slotId fields, envelope schema, session migration — part 3
- Any UI: cache debug glyph on lane cards is part 9 [R27]; telemetry stays log/test-only
- Appliance soak, cache hit-rate/xrun budget on the Pi, cap tuning — part 9
- Unity-render + post-volume optimization for linear-only chains (stated future refinement, not v3)

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh
```

## Notes

- **ffigen regen + `dart format`:** ffigen emits short-style and churns the
  entire bindings file; always run `dart format` after regen (the gotcha is
  documented in `ffigen.yaml` and `docs/PROGRESS.md`). The regen belongs in
  the same PR as the header change.
- **Test-runner sync:** `run_native_tests.sh` globs `src/core/engine*.c` but
  `src/CMakeLists.txt` lists sources explicitly — a new TU compiles in tests
  yet breaks the shipped build if the CMake list isn't updated in the same
  commit.
- **ASan scope:** `EXTRA_CFLAGS` covers only the engine + MIDI suites in the
  runner — the Darwin plugin scan/slot builds do not take it. The
  destroy-during-active-render test must live in `test_engine_core.c` so the
  sanitized job actually exercises it.
- **cspell + semantic PR title before opening the PR:** the fx-system-v3
  vocabulary (stomp, plog, FS-6, TRS — plus any new terms like "LRU",
  "debounce" variants this part introduces) must be in the cspell dictionary,
  and the PR title must pass the semantic-title check
  (`feat(engine): ...`). Check both before pushing, not after CI fails.
- **Stacked-PR squash landmines:** this part stacks on parts 1a/1b. After a
  parent squash-merges, rebase this branch onto the new base immediately —
  child merge-refs silently lose CI otherwise; never let the API delete the
  parent branch while this child is open (it auto-closes the child); any
  conflict resolution uses the child's-own-parent baseline.
- **Goldens:** not applicable — this part touches no widgets, so the
  author-only screenshot goldens stay untouched (do not regen them here).
- **Listen check:** the exit bar includes an A/B listen note on desktop
  (cached vs live, and the [B4] tail-drop on fallback). Float-tolerance
  tests are necessary but not sufficient — record the listen result in the
  PR body.
- **Threading review focus:** the [R2] contract clauses (a)–(d) are the
  highest-risk surface of this part; reviewers should be pointed at the
  enqueue copy, the atomic publish, the two-boundary reclaim, and the three
  join sites explicitly.
