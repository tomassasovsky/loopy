---
title: "feat(engine): track stereo bus + master insert"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Fable at high effort · `autonomy:merge-gate` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Give the engine the two missing FX stages: a **per-track stereo bus + Track
chain insert** inside `mix_tracks_frame`, and an **engine-level Master chain
insert** between `mix_tracks_frame` and `mix_monitors_frame`. Today chains
exist per-input (monitor) and per-lane only — "all loops of a track" never
exist as one stereo pair anywhere in the code, and Master is gain + limiter
only [R0]. This part creates the two new chain owners, their full setter API
mirroring the lane family, and pins the three routing decisions
(D-TRACKROUTE, D-MASTER, D-MASTERCH) with native tests — including the
empty-chain **bit-identical** guarantee that protects every existing session.

## Dependencies

- **Part 1a** — `docs/plan/2026-07-28-feat-fx-system-v3-part-1a-plan.md`
  (feat(engine): universal FX bypass — per-slot/per-chain `enabled` flags,
  click-free crossfade ramp in `fx_apply_chain`, plog enabled events,
  fingerprint enabled-bit folding, and the `snapshot_track_fx` →
  `snapshot_lane_fx` rename). **Must merge first**: this part reuses the
  enabled/ramp mechanism verbatim on the two new owners, passes part 1a's
  enabled arguments at its new `fx_apply_chain` call sites, and appends
  command-enum codes after part 1a's.

## Context

Everything below is engine-native work in `packages/segno_engine`. No domain,
session, UI, or pedal code changes in this part.

**Key files:**

- `packages/segno_engine/src/core/engine_private.h` — chain-owner shapes to
  mirror: `le_lane` (per-lane chain: `a_fx_count` / `a_fx_type` /
  `a_fx_param` / `le_fx_state fx`, `engine_private.h:231-263`) and
  `le_monitor_input` (`engine_private.h:266-286`); `le_track` struct
  (`engine_private.h:335-501`) gains the Track-stage owner; the engine
  struct gains the Master owner.
- `packages/segno_engine/src/core/engine_process.c` —
  `mix_tracks_frame` (`:3219-3461`): per-lane audible predicate + volume
  (`:3429-3432`), per-lane chain + individual routing via
  `le_fx_route(out, f, ch_out, out_mask[t][l] & out_enabled, wl, wr)`
  (`:3435-3441`) — the path that must stay **bit-identical** when the track
  chain is empty; `le_fx_route` (`:1500`); per-frame step decomposition
  convention (`:2395-2401`); `master_bus_frame` (gain + limiter + metering,
  `:2407-2450`) — the Master insert lands **before** this; per-frame call
  ordering `mix_tracks_frame` → `mix_monitors_frame` → `master_bus_frame` →
  `perf_tap_master_frame` → click → viz (`:3608-3643`); per-buffer chain
  snapshot helpers `snapshot_track_fx` (`:2941`, renamed `snapshot_lane_fx`
  by part 1a) and `snapshot_monitor_fx` (`:2969`), call sites `:3560-3579`;
  "first enabled output pair" precedent in `perf_tap_master_frame`
  (`:2459-2461`).
- `packages/segno_engine/src/core/engine_commands.c` — control-thread heap
  allocation contract `le_fx_prepare_entry` (`:1497-1517`: delay rings etc.
  allocated on the control thread, defaults seeded only on type change,
  publish via the ring's release/acquire pairing); the lane setter family to
  mirror: `le_engine_set_lane_fx` / `_count` / `_param`
  (`:1519-1573` — note `_param` is a direct atomic store, no ring).
- `packages/segno_engine/src/core/segno_engine_api.h` — `le_command` enum
  (`LE_CMD_SET_LANE_FX = 20` … monitor FX = 31/32, `:226-278`); lane API
  declarations (`:1436-1456`), monitor declarations (`:1491-1509`);
  `fx_added_latency_frames` doc (`:621-629`).
- `packages/segno_engine/src/core/engine_fx.c` — `fx_apply_chain`
  (`:983-994`; gains the enabled/ramp args in part 1a), `le_fx_prepare`,
  `le_fx_entry_reset`, `le_fx_defaults`.
- `packages/segno_engine/src/test/test_engine_core.c` +
  `packages/segno_engine/src/test/run_native_tests.sh` (source list must
  match `src/CMakeLists.txt`; `EXTRA_CFLAGS="-fsanitize=address -g"` for the
  ASan variant).
- `packages/segno_engine/ffigen.yaml` + `packages/segno_engine/lib/src/`
  (`audio_engine.dart`, `native_audio_engine.dart`, `mock_audio_engine.dart`,
  `generated/`) — bindings surface.
- `docs/design/performance-event-log-format.md` — command audit table [R3].

**Pinned decisions (index is source of truth — do not change):**

- **D-TRACKROUTE [R0]:** when a track's chain is **empty** (the default and
  the migration state), the per-lane routing path is **bit-identical to
  today** (preserves the migration fingerprint invariant). When a track
  chain is non-empty, its audible lanes sum into a stereo bus, the chain
  runs once, and the wet result routes via the **union of the lanes' enabled
  output masks** — a documented behavior change that only occurs when the
  user adds track FX to a divergent-mask config.
- **D-MASTER [R0]:** the master chain colors the track mix only; live
  monitor signals are summed after it and stay uncolored (keeps live-through
  sound predictable). A native test pins this. Placement: **between
  `mix_tracks_frame` and `mix_monitors_frame`, before master gain/limiter**
  — `master_bus_frame` itself (gain + limiter applied to tracks AND
  monitors) stays where it is, unchanged.
- **D-MASTERCH [R0]:** FX kernels are strict stereo; for `ch_out != 2` the
  master chain processes the **first enabled output pair** and passes other
  channels dry; `ch_out == 1` processes mono as `l == r`.
- Heap allocations (delay rings etc.) for the new owners stay on the
  **control thread** per the existing contract (`le_fx_prepare_entry`).
- Enabled flips use **direct atomic stores** (like params — no heap pointers
  move, so no ring needed) so they work while the device is stopped
  (part 1a mechanism, extended to the new owners here).
- **plog [R3]:** track/master setters are **manifest-only** per part 9's
  stems decision — they push **no** plog events; the audit table in
  `docs/design/performance-event-log-format.md` gets a "No replay" verdict
  row with rationale for every new command. `perf_render` replays nothing
  new from this part.

**Derived consequences this part pins with tests (follow directly from the
pinned wording — flag for review, don't silently change):**

- Topology keys off **emptiness, not enabled**: a non-empty but
  chain-disabled Track chain keeps the bus topology (union routing) with
  the part-1a bypass making it dry — a stomp toggles DSP, never routing.
  Only emptying the chain returns to the legacy per-lane path.
- The Track chain, like lane chains (`engine_process.c:3424-3428`), ticks
  every frame it is non-empty — even on silence — so delay tails and LFO
  phase stay continuous; the result is **routed** only via the union of the
  currently audible lanes' masks (no audible lane → chain ticks, routes
  nothing, mirroring the lane audible-gate at `:3439-3441`).

## Tasks

### 1. New chain owners (`engine_private.h`)

- [ ] Add a Track-stage chain owner to `le_track`
      (`engine_private.h:335-501`), shaped like `le_monitor_input`'s chain
      block: `_Atomic int32_t a_fx_count`, `_Atomic int32_t
      a_fx_type[LE_FX_MAX]`, `_Atomic uint32_t
      a_fx_param[LE_FX_MAX][LE_FX_PARAMS]`, its own `le_fx_state fx`, plus
      part 1a's `_Atomic int32_t a_fx_enabled[LE_FX_MAX]` (default 1) and
      `_Atomic int32_t a_fx_chain_enabled` (default 1). Name fields so they
      cannot be confused with the per-LANE chain (e.g. a nested
      `track_fx` / `bus` sub-struct) — part 1a's `snapshot_lane_fx` rename
      exists precisely so "track fx" now means this stage [VGV].
- [ ] Add the engine-level Master chain owner (same shape, one instance) to
      the engine struct. Document both with the D-TRACKROUTE / D-MASTER /
      D-MASTERCH semantics in the struct comments, matching the
      doc-comment density of `le_lane` / `le_monitor_input`.
- [ ] Zero-init both owners in engine create/configure exactly where
      lane/monitor chains are initialized; defaults: count 0, chain enabled
      1, per-slot enabled 1 (old sessions and fresh engines behave
      identically — dry).
- [ ] Free both owners' `le_fx_state` heap buffers (delay rings, reverb
      banks, octaver state) wherever lane/monitor `fx` state is freed in
      configure/destroy — no leak, ASan-clean.

### 2. Track stereo bus + insert in `mix_tracks_frame` (D-TRACKROUTE)

- [ ] Extend the per-buffer snapshot (pattern: `snapshot_lane_fx`,
      `engine_process.c:2941`, call site `:3566`) with the Track-stage chain
      config: per-track `trk_fx_count` / `trk_fx_type` / `trk_fx_params` /
      part-1a enabled bits, plus a per-track `trk_has_fx` gate mirroring
      `has_fx` — **`trk_has_fx[t]` is false when `a_fx_count == 0`**, and
      the accumulator path must not engage at all in that case.
- [ ] Empty-chain path (**bit-identity guarantee**): when `trk_has_fx[t]`
      is false, the existing per-lane code at `engine_process.c:3429-3441`
      runs untouched — same expressions, same `le_fx_route(out, …,
      out_mask[t][l] & out_enabled, wl, wr)` per lane. Structure the change
      as a branch **around** the legacy block, not a rewrite of it, so
      bit-identity is auditable in the diff.
- [ ] Non-empty path: per frame, accumulate each **audible** lane's post-
      lane-chain `(wl, wr)` into a per-track stereo pair instead of routing
      it individually; OR the audible lanes' `out_mask[t][l] & out_enabled`
      into a per-track union mask. Lane chains still run per lane exactly
      as today (their tails/DSP state must not change).
- [ ] Run `fx_apply_chain` once per track per frame on the track owner's
      `le_fx_state`, passing part 1a's enabled/ramp arguments; route the
      wet pair via `le_fx_route(out, f, ch_out, union_mask, l, r)`.
- [ ] Continuity: the Track chain ticks every frame the chain is non-empty
      (even when no lane is audible — input seeded 0,0), routing nothing
      when the union mask is empty; mirrors the lane-chain
      run-on-silence/route-when-audible split (`:3424-3441`).
- [ ] Chain-disabled (non-empty) keeps bus topology: part 1a's chain bypass
      yields dry-through-the-bus; routing does not revert to per-lane.
      Comment this at the branch with the D-TRACKROUTE rationale.
- [ ] Keep metering semantics unchanged: `lane_peak` / `lane_sumsq` /
      `frame_trk_peak` keep reading the dry `loopsample` as today
      (`:3443-3446`); do not re-point meters at the wet bus in this part.

### 3. Master insert (D-MASTER + D-MASTERCH)

- [ ] New `static inline` per-frame step (the `:2395-2401` decomposition
      convention), e.g. `master_fx_frame(...)`, called in
      `le_engine_process` **between** `mix_tracks_frame` and
      `mix_monitors_frame` (call sites `:3608-3617`): processes the
      track-mix already accumulated in `out[f*ch_out + c]`, so monitors —
      summed after it — stay uncolored. `master_bus_frame`
      (gain/limiter/metering, `:2407-2450`) is untouched and still runs
      after `mix_monitors_frame`, so monitors keep getting master gain +
      limiter exactly as today.
- [ ] Per-buffer snapshot of the Master chain config (count/types/params/
      enabled) alongside the other snapshot helpers; `has_fx`-style gate:
      empty Master chain = zero-cost skip, **bit-identical** output.
- [ ] D-MASTERCH channel mapping inside the step: `ch_out == 2` → process
      the pair; `ch_out > 2` → process the **first enabled output pair**
      (out_enabled precedent: `perf_tap_master_frame`, `:2459-2461`) wet,
      pass every other channel through untouched (bit-exact dry);
      `ch_out == 1` → process mono as `l == r`, write back one channel.
- [ ] Runs on the Master owner's `le_fx_state` with part 1a's enabled/ramp
      arguments; chain-disabled = dry via the part-1a bypass ramp.
- [ ] The perf master tap (`perf_tap_master_frame`) keeps capturing
      post-limiter output — the Master chain is upstream of it; no tap
      change. Note this in the step's doc comment (stems/manifest decision
      is parts 3/9).

### 4. API + ring commands (`segno_engine_api.h`, `engine_commands.c`)

- [ ] New command codes appended to the `le_command` enum **after part 1a's
      last code** (coordinate on rebase — both parts append):
      `LE_CMD_SET_TRACK_FX`, `LE_CMD_SET_TRACK_FX_COUNT`,
      `LE_CMD_SET_MASTER_FX`, `LE_CMD_SET_MASTER_FX_COUNT`, with doc
      comments matching the `:226-278` style (which typed arm carries what;
      master commands need no channel).
- [ ] Control-thread setters mirroring the lane family
      (`engine_commands.c:1519-1573`), with identical validation shape
      (range-check channel/index/type/count/param, clamp values):
      - `le_engine_set_track_fx(engine, channel, index, type)`,
        `le_engine_set_track_fx_count`, `le_engine_set_track_fx_param`
      - `le_engine_set_master_fx(engine, index, type)`,
        `le_engine_set_master_fx_count`, `le_engine_set_master_fx_param`
      Type/count go via the ring (audio thread resets the entry's DSP state
      in lockstep via `le_fx_entry_reset`, exactly like
      `LE_CMD_SET_LANE_FX`); `_param` is a direct atomic store.
- [ ] Both `set_*_fx` setters call `le_fx_prepare_entry`
      (`engine_commands.c:1497-1517`) on the new owners **before** pushing
      the ring command — the control-thread heap allocation contract:
      delay rings allocated control-side, made visible by the ring's
      release/acquire pairing; allocation failure returns
      `LE_ERR_INVALID` with buffers left as they were.
- [ ] Enabled setters extending part 1a's family to the new owners:
      `le_engine_set_track_fx_enabled` / `le_engine_set_track_fx_chain_enabled`
      + master twins — **direct atomic stores** (work while stopped), same
      signature shape as part 1a's lane/monitor versions.
- [ ] Audio-thread dispatch for the four new ring codes in the command
      drain, mirroring the lane FX cases (reset DSP state on type change;
      clamp count).
- [ ] **No plog pushes** from any track/master setter [R3]; instead add a
      verdict row per new command to the audit table in
      `docs/design/performance-event-log-format.md`: "No replay —
      manifest-only; stems stay per-stage dry-of-downstream (part 9), arm
      manifest carries track/master chains (part 3)."
- [ ] API doc comments in `segno_engine_api.h` state the pinned semantics:
      empty-chain bit-identity + union-mask routing (track), monitors
      uncolored + first-enabled-pair mapping (master), enabled-flips-work-
      while-stopped.
- [ ] Leave `fx_added_latency_frames` (`segno_engine_api.h:621-629`)
      semantics untouched: it exists for record-alignment of the monitored
      path; Track/Master chains sit post-capture and do not affect record
      alignment. Note this in the new setters' doc comments.

### 5. Bindings

- [ ] ffigen regen (`dart run ffigen --config ffigen.yaml`) **followed by
      `dart format`** on the generated file (ffigen emits short-style code;
      unformatted regen churns the whole file — `ffigen.yaml:5`).
- [ ] Extend the Dart surface following the lane-setter pattern:
      `audio_engine.dart` (abstract interface), `native_audio_engine.dart`
      (FFI pass-through), `mock_audio_engine.dart` (recording no-op) for
      all twelve new setters (fx/count/param/enabled/chain-enabled ×
      track/master).
- [ ] Extend the package's existing engine-binding Dart tests wherever the
      lane family is covered (mock recording + native argument
      pass-through), keeping package coverage at its gate.

### 6. Native tests (`test_engine_core.c`) — all three decisions pinned

D-TRACKROUTE:

- [ ] **Bit-identity (empty):** identical scenario on (a) an engine that
      never touched the track chain and (b) one that set a track chain then
      emptied it (`count = 0`) → outputs **exactly equal** (memcmp-grade,
      no tolerance). Additionally: zero expectation changes in the existing
      mix/routing tests — they are the pre-part-1b oracle.
- [ ] **Union routing:** two lanes with divergent output masks + non-empty
      track chain (use a unity-ish effect or measure wet energy) → signal
      appears on the union of both masks; individual per-lane placement
      gone; a structurally disabled output (`out_enabled`) never carries
      bus energy.
- [ ] **Audible-only summing:** a muted lane and a stopped track contribute
      nothing to the bus; unmuting mid-run brings the lane in without
      discontinuity beyond the part-1a ramp spec.
- [ ] **Topology keys off emptiness:** non-empty chain +
      `a_fx_chain_enabled = 0` → dry signal but still union-routed (assert
      placement on the union under divergent masks); emptying the chain
      restores the per-lane bit-identical path.
- [ ] **Tail continuity:** track-chain delay tail continues across
      all-lanes-muted → unmuted (chain ticks on silence; routes nothing
      while the union is empty).

D-MASTER:

- [ ] **Monitors uncolored:** loop playback + an enabled live monitor with
      a strongly coloring master chain (e.g. full-wet delay) → the
      monitor-only component of the output equals the no-master-chain run
      (extract by differencing runs); the loop component is colored.
- [ ] **Placement before gain/limiter:** a master-chain gain boost drives
      the limiter (post-insert level above ceiling engages `lim_gain`);
      empty master chain → output bit-identical to today.

D-MASTERCH:

- [ ] `ch_out == 2`: both channels wet.
- [ ] `ch_out == 4` (first pair enabled): channels 0/1 wet, 2/3 **bit-exact
      dry**; with channel 0 structurally disabled, the first *enabled* pair
      is the processed one.
- [ ] `ch_out == 1`: mono processed as `l == r`; result matches the stereo
      run's left channel for a symmetric chain.

API/lifecycle:

- [ ] Setter validation: out-of-range channel/index/type/count/param →
      `LE_ERR_INVALID`, state untouched.
- [ ] Enabled + chain-enabled flips on track/master owners work while the
      device is stopped (direct store) and take effect on the next process
      call.
- [ ] `le_fx_prepare_entry` reuse: setting a delay on the track and master
      chains allocates control-side and processes without audio-thread
      allocation; type re-set preserves tweaked params (no default re-seed).
- [ ] Lifecycle: configure/destroy with populated track + master chains
      (delay + reverb entries) leaks nothing — run the suite once with
      `EXTRA_CFLAGS="-fsanitize=address -g"` locally and in CI's ASan job.

### 7. Docs + PR

- [ ] `docs/design/performance-event-log-format.md`: "No replay" verdict
      rows for all new commands (task 4).
- [ ] Child issue for this part under #351, labeled `stage:build` + an
      `autonomy:*` (suggest `autonomy:merge-gate` — hot-path mix changes
      are taste/blast-radius; escalate to `plan-gate` if a routing design
      call emerges beyond the pinned decisions).
- [ ] PR: `Closes #<child>` in the body; labels `stage:in-review`,
      `autonomy:*`, `ci:*`, `review:pending`; check the cspell dictionary
      (new vocabulary from this part, e.g. "TRACKROUTE"/"MASTERCH" if they
      appear in prose) + semantic PR title **before** opening.

## Success Criteria

```success-criteria
GOAL: Real Track and Master FX stages in the engine — per-track stereo bus + master insert with full setter API — while an empty chain keeps today's routing bit-identical and live monitors stay uncolored.

SUCCESS CRITERIA:
- D-TRACKROUTE pinned: empty-chain path bit-identical (existing test expectations untouched + set-then-empty equality test); non-empty chain sums audible lanes, runs once, routes via the union of enabled lane masks; disabled-but-non-empty keeps bus topology; tail continuity across mute | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- D-MASTER pinned: master insert sits between mix_tracks_frame and mix_monitors_frame, before master gain/limiter; monitors uncolored by the master chain; empty master chain bit-identical | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- D-MASTERCH pinned: ch_out==2 wet pair; ch_out>2 first enabled pair wet, others bit-exact dry; ch_out==1 mono as l==r | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Full track/master setter family (fx/count/param + enabled/chain-enabled twins) mirrors the lane family: ring for type/count with lockstep DSP reset, direct atomic stores for param/enabled (work while stopped), le_fx_prepare_entry control-thread allocation, validation returns LE_ERR_INVALID | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- No plog events from track/master setters; audit table in docs/design/performance-event-log-format.md has a "No replay" verdict row per new command | verify: bash packages/segno_engine/src/test/run_native_tests.sh && grep -q "SET_TRACK_FX" docs/design/performance-event-log-format.md
- Lifecycle clean: configure/destroy with populated track+master chains is leak-free under ASan | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh
- Dart bindings regenerated (ffigen + dart format) and the interface/native/mock trio extended; package suite green | verify: /Users/Tomas/development/flutter/bin/flutter test packages/segno_engine

NON-GOALS:
- Per-slot/per-chain enabled mechanism, crossfade ramp, no-tail-spill semantics, plog enabled events, fingerprint enabled-bit folding, snapshot_track_fx -> snapshot_lane_fx rename — part 1a owns these (this part only extends them to the new owners)
- Loop-stage wet cache — part 2
- Domain model, chain envelope, session persistence, LooperBloc events, arm() fix, engine fingerprint APIs for the new stages — part 3
- Signal-page UI for Track/Master stages — part 4
- Plugin-slot loading (le_engine_plugin_load) targeting track/master chains — not tasked by the index for part 1; built-in effects only through these setters, surface any need in part 3+
- Any change to master gain/limiter placement, monitor gain/limiter behavior, metering semantics, or fx_added_latency_frames
- daw_export / stems rendering of the new stages — part 9 (manifest-only decision already pinned)

VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```

## Notes

- **Stacked on part 1a — squash landmines.** Part 1a squash-merges before
  this part's PR targets master; rebase this branch onto post-merge master
  (child merge-ref CI is silently absent on stale stacked PRs, and an API
  branch-delete can auto-close the child). Both parts append `le_command`
  enum codes — take the next free values after 1a's on rebase, never
  renumber existing codes.
- **ffigen regen churn.** ffigen emits legacy short-style code; run
  `dart format` on the generated file immediately after regen or the diff
  is whole-file noise (`ffigen.yaml:5`, `docs/PROGRESS.md`).
- **Test runner source list.** `run_native_tests.sh` compiles an explicit
  source list that must match `src/CMakeLists.txt`'s `add_library` list —
  this part should need no new TU, but if one is added, update both.
- **Bit-identity is the migration fingerprint invariant.** Do not "clean
  up" the legacy per-lane block while adding the bus branch — the existing
  native test expectations are the oracle, and any expectation change in
  them is a red flag, not a test update.
- **The rename must land first.** Part 1a renames `snapshot_track_fx` →
  `snapshot_lane_fx`; this part introduces a genuine track-STAGE snapshot.
  If the rename somehow hasn't landed at build time, stop and resolve the
  naming before adding the new helper — "track_fx" must not mean two things
  in one file [VGV].
- **plog discipline.** Track/master setters push nothing; resist the
  symmetry urge to mirror the lane plog events — the "No replay" audit rows
  with rationale are the deliverable [R3]. Part 3 carries chains in the arm
  manifest; part 9 owns the export story.
- **cspell + PR title.** Check the cspell dictionary for new prose tokens
  and the semantic PR title convention before opening the PR, not after CI
  fails.
- **Goldens.** No UI in this part — screenshot goldens are not touched
  (they are author-machine-only; relevant to parts 4/6, not here).
- **macOS test build.** Use the documented runner only; the very_good MCP
  test wrapper is broken in this repo — native suite via
  `bash packages/segno_engine/src/test/run_native_tests.sh`, Dart via the
  absolute Flutter path `/Users/Tomas/development/flutter/bin/flutter`.
