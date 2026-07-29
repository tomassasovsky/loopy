---
title: "feat(engine): universal per-slot + per-chain FX enable with click-free ramp"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

## Overview

Give the engine a universal, atomic, click-free `enabled` concept for FX — a
per-slot flag plus a per-chain flag on the two chain owners that exist today
(**lanes** and **monitor inputs**) — with a ~5 ms dry/wet crossfade ramp inside
`fx_apply_chain`, documented no-tail-spill semantics [B7], performance-log
events + replay [R3], and fingerprint lockstep with the Dart mirror [R4][R16].
This is the keystone the whole FX-v3 epic (#351) stands on: pedal stomps
(parts 5–6), the wet cache key (part 2), and the UI power controls (part 4)
all consume exactly this surface. Track/master chain owners, the track bus,
and the master insert are **part 1b** — not here.

## Dependencies

None. This is the root of the part-1 stack: `2026-07-28-feat-fx-system-v3-part-1b-plan.md`
(track bus + Track/Master inserts) stacks on top of this part, not the other
way around.

## Context

Lifted from the epic index (`docs/plan/2026-07-28-feat-fx-system-v3-plan.md`,
Part 1 + Problem Statement), narrowed to the lane/monitor slice:

- **No bypass exists today.** The only "off" for a built-in effect is deleting
  it (parameters lost). `fx_apply_chain` processes every slot unconditionally
  (`packages/loopy_engine/src/core/engine_fx.c:978-999`); `le_fx_state` has no
  enabled flag (`engine_private.h:196-216`). Pedal FX toggling is impossible
  today.
- **Chain owners in scope:** `le_lane` (`engine_private.h:230-261`,
  `a_fx_count`/`a_fx_type`/`a_fx_param` at 257-259) and `le_monitor_input`
  (`engine_private.h:274-283`). NO track/master owners in this part.
- **`fx_apply_chain` call sites (all four must gain the enabled argument):**
  - monitor path: `engine_process.c:3117`
  - lane path: `engine_process.c:3436`
  - offline replay: `perf_render.c:1110`
  - test helper `le_engine_lane_fx_chain_for_test`: `engine.c:504-522`
- **Per-buffer snapshot pattern:** `snapshot_track_fx` (`engine_process.c:2941`,
  actually per-LANE — renamed this part) and `snapshot_monitor_fx`
  (`engine_process.c:2969`), called at `engine_process.c:3560-3579`; `has_fx`
  gating stays unchanged.
- **Direct-atomic setter precedent:** params are plain published atomics with
  a race-free direct store + `le_plog_push_ctrl`, no ring command, working
  whether or not the device runs (`engine_commands.c:1550-1572` lane,
  `engine_commands.c:1636-1652` monitor). Enabled flips follow this exact
  pattern — no heap pointers move, so no ring needed; they work while stopped.
- **DSP reset primitive:** `le_fx_entry_reset` (`engine_fx.c:607-623`) already
  runs on the AUDIO THREAD from the SET_*_FX ring handlers
  (`engine_process.c:2101`, `:2194`); its RT note blesses the bounded cost.
  Re-enable reuses it.
- **Performance event log:** control-side plog codes live in
  `perf_log_ring.h:60-89` (last used code: `LE_PLOG_SET_OVERDUB_FEEDBACK = 309`);
  the audit doc is `docs/design/performance-event-log-format.md` (audited
  command table ~line 85, perf-log-only codes table ~line 138). Every new
  command needs a verdict row [R3].
- **Fingerprint:** `le_fx_chain_fingerprint` + the lane/monitor entry points
  (`engine_snapshot.c:102-138`; `le_engine_lane_fx_fingerprint` at 125,
  `le_engine_monitor_fx_fingerprint` at 135). Dart mirror:
  `packages/loopy_engine/lib/src/fx_fingerprint.dart` (`FxFingerprint`
  primitives) + `trackChainFingerprint` in
  `packages/looper_repository/lib/src/models/track_effect.dart:357`, proven in
  lockstep by
  `packages/looper_repository/test/fx_fingerprint_agreement_test.dart` and
  unit-covered in `packages/looper_repository/test/models/track_effect_test.dart:276-333`.
  Both sides must change **in the same PR** [R4][R16].
- **Record-time inheritance is host-driven:** the engine takes NO self-snapshot
  on record — `LooperRepository` is the sole record-time snapshot authority and
  pushes lane FX through the ring (`engine_commands.c:691-698`). The
  `le_monitor_input` doc comment claiming "`le_engine_record` deep-copies"
  (`engine_private.h:272-273`) is stale and contradicts it.
- **Dart engine API:** `AudioEngine` (`packages/loopy_engine/lib/src/audio_engine.dart`,
  existing `setLaneFx`/`setLaneFxParam` at 475/493, `setMonitorInputFx`/`...FxParam`
  at 543/556) + `NativeAudioEngine` + `MockAudioEngine`; ffigen config
  `packages/loopy_engine/ffigen.yaml`, generated bindings in
  `packages/loopy_engine/lib/src/generated/`.
- **Native test gate:** `packages/loopy_engine/src/test/test_engine_core.c`,
  runner `bash packages/loopy_engine/src/test/run_native_tests.sh` ("ALL
  PASSED" twice).

### Pinned decisions (from the index — do not reopen)

- Click-free engage = per-slot dry/wet crossfade ramp (~5 ms) driven by the
  enabled-flag transition inside `fx_apply_chain`; DSP state reset on
  re-enable via existing `le_fx_entry_reset`.
- **Documented behavior: no tail spill on bypass** [B7] — disabling an effect
  fades its wet output (tail included) over the ramp; the tail does not keep
  ringing into the dry signal.
- Enabled flips use **direct atomic stores** (params pattern — no ring), so
  they work while stopped.
- Plog events mirror the params pattern via `le_plog_push_ctrl` [R3]; audit
  table rows for every new command; replay in `perf_render`'s per-frame
  switch; its `fx_apply_chain` call gains the enabled arg regardless.
- Chain fingerprint folds enabled bits, and the Dart mirror
  `trackChainFingerprint` updates in the same PR folding the default
  enabled=1 until part 3 carries the field, keeping
  `fx_fingerprint_agreement_test.dart` green [R4][R16].
- Rename `snapshot_track_fx` → `snapshot_lane_fx` while the file churns: it
  snapshots per-LANE chains, and part 1b introduces a real track-stage chain —
  "track_fx" must not mean two things in one file [VGV].
- `has_fx` gating unchanged.
- ffigen regen + `dart format` (known churn gotcha), Dart bindings.

### Part-1a-local pins (new, engine-semantics level)

- **D-EFFBITS:** the audio thread consumes one **effective** bit per slot,
  computed in the per-buffer snapshot as `chain_enabled && slot_enabled`. One
  ramp mechanism serves both flag levels (a chain-disable ramps every active
  slot to dry); `fx_apply_chain` itself never distinguishes chain vs slot.
- **D-BITEXACT:** a slot whose ramp has settled fully bypassed is **skipped
  entirely** (same shape as the existing `LE_FX_NONE` skip) — bit-exact
  passthrough by construction, not by arithmetic identity.
- **D-ENSEED:** an ACTUAL type change on a slot re-seeds its `enabled` to 1,
  mirroring how `le_fx_prepare_entry` re-seeds param defaults only on a real
  type change (guarded `!= type`, `engine_fx.c` / `engine_commands.c:1615`) —
  a freshly placed effect starts enabled; a same-type re-set (reorder writing
  the same type back) touches nothing. Prevents a stale disabled flag from
  silently muting a future chain pushed onto a recycled slot.
- **D-FPEMPTY:** the fingerprint folds the chain-enabled bit only for a
  NON-empty chain, and folds each entry's slot bit after its type. An empty
  chain keeps hashing to the FNV offset basis — semantically honest
  (chain-disabled empty ≡ enabled empty ≡ dry) and preserves the documented
  empty-chain invariant (`loopy_engine_api.h:1627` comment,
  `track_effect_test.dart:280`).

### Risks

| Risk | Mitigation |
|------|------------|
| Toggle clicks/zipper noise | ~5 ms linear per-sample crossfade; ramp-continuity native test bounds sample-to-sample delta |
| Delay/reverb tail bleeds past bypass | No-tail-spill semantics [B7]: settled slot stops processing; dedicated native test with an echo chain |
| Stale ring content bursts on re-enable | Audio-thread `le_fx_entry_reset` on the 0→1 edge (precedented, bounded per its RT note); native test |
| Old sessions / existing behavior change | Flags default 1 everywhere; defaults native test proves default-flag output ≡ pre-change output bit-exactly |
| Fingerprint drift between C and Dart | Fold order pinned (D-FPEMPTY); both sides in one PR; agreement test is the gate [R4][R16] |
| Stomps invisible in performance capture | Plog codes 310–313 + audit rows + lane replay in `perf_render` [R3] |
| ffigen regen whole-file churn | `dart format` after regen (documented drift gotcha) |

## Tasks

### 1. Engine state (`engine_private.h`)

- [ ] `le_lane` gains `_Atomic int32_t a_fx_enabled[LE_FX_MAX]` (per-slot,
      default 1) and `_Atomic int32_t a_fx_chain_enabled` (default 1), placed
      with the existing published-chain block (`engine_private.h:257-259`);
      update the "per-lane effects chain" doc comment to describe the two
      flag levels and the no-tail-spill contract [B7].
- [ ] `le_monitor_input` gains the identical pair
      (`engine_private.h:279-281` block); update its doc comment — and fix
      the stale "`le_engine_record` deep-copies" sentence
      (`engine_private.h:272-273`) to match the host-as-snapshot-authority
      reality (`engine_commands.c:691-698`).
- [ ] `le_fx_state` gains the audio-thread-owned ramp runtime: per-slot
      crossfade position (`float enable_mix[LE_FX_MAX]`, 1.0 = fully wet) and
      last-observed effective target (`int32_t enable_target[LE_FX_MAX]`) for
      edge detection (`engine_private.h:196-216`); document that these are
      DSP state (audio-thread-owned), not published config.
- [ ] Seed defaults where lanes/monitors are (re)initialized —
      `le_lane_reset` / `le_monitor_input_reset` (call sites `engine.c:160`,
      `engine.c:190`): flags = 1, ramp state settled at the current effective
      target so fresh chains do not fade in on first use. Old sessions load
      through existing setters and never touch the flags → everything
      enabled, defaults test in task 8.

### 2. Click-free ramp in `fx_apply_chain` (`engine_fx.c`)

- [ ] `fx_apply_chain` (`engine_fx.c:978`) gains a `const int32_t* enabled`
      argument (per-slot **effective** bits per D-EFFBITS); declaration in
      `engine_fx.h:45` updated.
- [ ] Ramp spec: ~5 ms linear dry/wet crossfade, one named constant (e.g.
      `LE_FX_ENABLE_RAMP_MS = 5`), per-sample step derived from `sr`.
- [ ] Disable edge (target 1→0): the slot KEEPS processing while
      `enable_mix` ramps to 0 (the wet branch — tail included — fades out),
      then the slot is skipped entirely once settled (D-BITEXACT). This IS
      the no-tail-spill behavior [B7]; document it in the `fx_apply_chain`
      header comment.
- [ ] Enable edge (target 0→1): call `le_fx_entry_reset(fx, slot)` on the
      audio thread at the edge (precedented + bounded per the RT note at
      `engine_fx.c:596-607`), then ramp dry→wet from 0 — stale integrators or
      ring content never sound.
- [ ] Update all four call sites to pass the effective-enabled snapshot:
      `engine_process.c:3117` (monitor), `engine_process.c:3436` (lane),
      `perf_render.c:1110` (replay — see task 5), `engine.c:504-522`
      (`le_engine_lane_fx_chain_for_test`, which snapshots the lane's flags
      like it snapshots types/params today).

### 3. Per-buffer snapshot (`engine_process.c`)

- [ ] Rename `snapshot_track_fx` → `snapshot_lane_fx` (`engine_process.c:2941`,
      the mirror-comment at `:2968`, the call-site comment + calls at
      `:3560-3579`, and any other textual references) [VGV].
- [ ] `snapshot_lane_fx` and `snapshot_monitor_fx` additionally read
      `a_fx_chain_enabled` + `a_fx_enabled[]` once per buffer and emit the
      per-slot **effective** bit arrays (D-EFFBITS) the callers hand to
      `fx_apply_chain`.
- [ ] `has_fx` gating unchanged: a lane/monitor with a disabled chain still
      enters `fx_apply_chain` so in-flight ramps can settle; only settled
      slots are skipped inside the chain (D-BITEXACT).

### 4. API + setters (`loopy_engine_api.h`, `engine_commands.c`)

- [ ] Four new exports beside the existing FX setters
      (`loopy_engine_api.h:1442-1508`):
      `le_engine_set_lane_fx_enabled(engine, channel, lane, index, enabled)`,
      `le_engine_set_lane_fx_chain_enabled(engine, channel, lane, enabled)`,
      `le_engine_set_monitor_input_fx_enabled(engine, input, index, enabled)`,
      `le_engine_set_monitor_input_fx_chain_enabled(engine, input, enabled)`.
      Doc comments state: direct atomic publish (no ring), works while
      stopped, click-free ramp on the running audio thread, no tail spill on
      bypass [B7], re-enable resets DSP state.
- [ ] Implement as direct atomic stores following the params pattern
      (`engine_commands.c:1550-1572` / `:1636-1652`): validate ranges,
      normalize to 0/1, `store_i32`, then `le_plog_push_ctrl` (task 5),
      return `LE_OK`.
- [ ] D-ENSEED: in `le_engine_set_lane_fx` / `le_engine_set_monitor_input_fx`,
      an ACTUAL type change (the existing `!= type` guard that already
      re-seeds param defaults) also stores `enabled = 1` for that slot;
      a same-type set leaves the flag untouched.

### 5. Performance event log [R3] (`perf_log_ring.h`, `engine_commands.c`, `perf_render.c`, docs)

- [ ] New codes in `perf_log_ring.h` (after 309):
      `LE_PLOG_SET_LANE_FX_ENABLED = 310` (`fx` arm: `{channel, lane, index,
      type = enabled 0/1}`),
      `LE_PLOG_SET_LANE_FX_CHAIN_ENABLED = 311` (`lanef` arm: `{channel,
      lane, value = 0/1}`, matching `LE_CMD_SET_LANE_MUTE`'s shape),
      `LE_PLOG_SET_MONITOR_FX_ENABLED = 312` (`fx` arm: `channel` = input,
      `lane` = -1, matching 307's convention),
      `LE_PLOG_SET_MONITOR_FX_CHAIN_ENABLED = 313` (`generic` arm:
      `arg_i` = input, `arg_f` = enabled, matching monitor volume/mute).
      Each setter in task 4 pushes its event via `le_plog_push_ctrl`.
- [ ] `docs/design/performance-event-log-format.md`: one verdict row per new
      code in the perf-log-only table (payload documented as above), with
      explicit replay verdicts — lane codes: "replayed in the lane wet pass";
      monitor codes: "logged for the manifest/reader, not replayed in the
      lane pass" (mirroring `LE_PLOG_SET_MONITOR_FX_PARAM = 307`'s existing
      treatment). Note that arm-time enabled bits in the manifest land in
      part 3 [R3].
- [ ] `perf_render.c`: the replayed chain state (the `chain` struct feeding
      the per-frame switch at `perf_render.c:1074`-area) gains
      `enabled[LE_FX_MAX]` + `chain_enabled`, seeded all-1 at arm (the
      manifest carries no bits until part 3); add `case` arms for 310/311
      (channel + lane 0 filter, like `LE_PLOG_SET_LANE_FX_PARAM`); compute
      effective bits per frame and pass them to the `fx_apply_chain` call at
      `perf_render.c:1110`.

### 6. Fingerprint lockstep [R4][R16] (`engine_snapshot.c` + Dart mirror, same PR)

- [ ] `le_fx_chain_fingerprint` (`engine_snapshot.c:106-124`) gains the flag
      inputs (chain flag + per-slot flag atomics) and folds them per
      D-FPEMPTY: chain-enabled first (only when `count > 0`); per entry:
      type, then slot-enabled bit, then params (plugin entries: type +
      enabled bit only). `le_engine_lane_fx_fingerprint` (`:125`) and
      `le_engine_monitor_fx_fingerprint` (`:135`) thread the new fields;
      exported signatures unchanged.
- [ ] Dart mirror `trackChainFingerprint`
      (`packages/looper_repository/lib/src/models/track_effect.dart:357`)
      folds constant `1` in the identical positions (chain bit for non-empty
      chains, per-entry bit after the type) until part 3 carries the real
      field; doc comment records the pinned fold order and the part-3
      handoff. `FxFingerprint` primitives (`fx_fingerprint.dart`) unchanged.
- [ ] `fx_fingerprint_agreement_test.dart` stays green (the merge gate for
      this task); `track_effect_test.dart:276-333` expectations reviewed —
      the empty-chain → offset-basis case must still hold (D-FPEMPTY).

### 7. ffigen + Dart bindings (`packages/loopy_engine`)

- [ ] Regenerate bindings from `packages/loopy_engine/ffigen.yaml`, then
      `dart format` the generated file (ffigen emits short-style → whole-file
      churn otherwise — documented gotcha).
- [ ] `AudioEngine` interface gains `setLaneFxEnabled`,
      `setLaneFxChainEnabled`, `setMonitorInputFxEnabled`,
      `setMonitorInputFxChainEnabled` (named-parameter style matching
      `setLaneFxParam`, `audio_engine.dart:475-560`), with doc comments
      carrying the ramp + no-tail-spill + works-while-stopped contract;
      implement in `NativeAudioEngine`; record in `MockAudioEngine`.
- [ ] `packages/loopy_engine` Dart tests cover the new API surface (mock
      recording + `pumped_native_engine_test.dart` smoke where it exercises
      setters today) so package coverage holds.
- [ ] No `looper_repository` domain changes beyond the fingerprint mirror —
      the `enabled` field on `TrackEffect`, envelope, and setters are
      part 3's scope.

### 8. Native tests (`test_engine_core.c`) — the merge gate

- [ ] **Ramp continuity:** steady tone through an enabled DRIVE (or FILTER)
      slot; toggle enabled mid-render; assert the maximum sample-to-sample
      output delta never exceeds the bound implied by the 5 ms ramp (no step
      discontinuity above ramp spec).
- [ ] **Bit-exact passthrough:** slot disabled, ramp settled → output is
      bit-exact (memcmp) against the same render with no FX (D-BITEXACT);
      repeat at the chain level (chain flag off, slot flags untouched).
- [ ] **No tail spill [B7]:** ECHO/DELAY chain fed a burst; disable
      mid-decay; after the ramp window the output contains no delayed
      repeats — dry only.
- [ ] **Re-enable resets DSP:** load a delay ring with signal, disable, feed
      silence, re-enable → output stays silent after the ramp (stale ring
      content never sounds; `le_fx_entry_reset` observed).
- [ ] **Defaults / old sessions:** a chain pushed only through the existing
      setters (no enabled calls) renders bit-identical to the pre-change
      engine's semantics — all flags read 1, `has_fx` path unchanged.
- [ ] **D-ENSEED:** disable a slot; actual type change → flag reads 1 again;
      same-type re-set → flag stays 0.
- [ ] **Works while stopped:** enabled setters called before start return
      `LE_OK` and are honored by the first rendered buffer.
- [ ] **Monitor twins:** monitor per-slot + chain disable → monitor path
      passthrough dry (mirror of the lane cases).
- [ ] **Plog + replay:** toggles during an armed capture appear in the event
      log with codes 310–313 and pinned payloads; `perf_render` lane replay
      flips the wet output at the logged frame (extend the existing
      golden-parity/replay coverage).
- [ ] **Fingerprint:** flipping a slot or chain flag changes
      `le_engine_lane_fx_fingerprint` / `..._monitor_fx_fingerprint`;
      empty chain still hashes to the offset basis (D-FPEMPTY).
- [ ] Full suite: `bash packages/loopy_engine/src/test/run_native_tests.sh`
      → "ALL PASSED" twice.

## Success Criteria

```success-criteria
GOAL: Every lane and monitor FX slot and chain can be atomically enabled/disabled, click-free (~5 ms ramp), with no tail spill, logged + replayable, fingerprinted in C/Dart lockstep — and default-enabled behavior is bit-identical to today's engine.

SUCCESS CRITERIA:
- Ramp continuity: mid-tone toggle produces no discontinuity above the 5 ms ramp spec, both flag levels, lane + monitor | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Bit-exact passthrough: a settled disabled slot (and a disabled chain) renders memcmp-identical to no-FX; default flags render bit-identical to the pre-change engine | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- No tail spill on bypass [B7] + re-enable resets DSP state via le_fx_entry_reset | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Direct-atomic setters work while stopped and return LE_OK; D-ENSEED type-change re-seed proven | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Plog events 310-313 emitted with pinned payloads; perf_render lane replay flips wet at the logged frame [R3]; doc audit rows added | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Fingerprint folds enabled bits (D-FPEMPTY order) and the Dart mirror agrees in the same PR [R4][R16] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository packages/loopy_engine
- snapshot_track_fx renamed snapshot_lane_fx with all references [VGV]; ffigen regenerated + formatted, new Dart API on AudioEngine/Native/Mock | verify: /Users/Tomas/development/flutter/bin/flutter analyze packages/loopy_engine && bash packages/loopy_engine/src/test/run_native_tests.sh

NON-GOALS:
- Track/master chain owners, the track stereo bus, the Master insert, D-MASTER / D-TRACKROUTE / D-MASTERCH (part 1b)
- Loop-stage wet cache and its enabled-bits cache key (part 2)
- Domain `enabled`/`slotId` on TrackEffect, chain envelope, session/settings persistence, arm-manifest enabled bits, trackChainFingerprint rename (part 3)
- UI power controls / _BypassToggle replacement (part 4)
- Pedal FX mode and stomp bindings (parts 5-6)

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh
```

## Notes

- **ffigen churn gotcha:** ffigen emits short-style code → whole-file diff
  churn; always run `dart format` on the regenerated bindings (documented in
  `ffigen.yaml` + `docs/PROGRESS.md`). The native test runner's source glob
  (`run_native_tests.sh` `ENGINE_SRC`) already globs `engine*.c` — no runner
  edit needed unless a new TU is added (avoid adding one; this part fits in
  existing TUs).
- **Native test runner:** the very_good MCP test wrapper is broken for this
  repo — use the absolute flutter path
  (`/Users/Tomas/development/flutter/bin/flutter`) for Dart suites and
  `bash packages/loopy_engine/src/test/run_native_tests.sh` for C. The engine
  suite must print "ALL PASSED" twice (engine + MIDI).
- **Before opening the PR:** check the cspell dictionary for any new tokens
  (e.g. `ENSEED`, `EFFBITS`, `FPEMPTY`, `plog` variants) and the semantic PR
  title rule — check BEFORE the PR, not after CI fails.
- **Stacked-PR squash landmines:** this PR is the base of the part-1 stack
  (part 1b stacks on it). Squash-merging breaks child merge-refs (CI silently
  absent on the child) and API branch-deletes close children — rebase the
  child onto master after this lands, per repo stacked-PR discipline.
- **Coverage:** CI runs the root app Dart test job (`flutter_package.yml`,
  min_coverage 90) — the new `AudioEngine` methods must be covered via the
  mock/native tests, or the job fails. The per-package CI-gate fix for
  `looper_repository` et al. is part 3's task; until then the fingerprint
  agreement test runs locally as this part's Dart gate — run it explicitly,
  don't rely on CI to catch drift.
- **Goldens:** no UI in this part — screenshot goldens are not affected (they
  are author-machine-only; relevant to parts 4 and 6, not here).
- **Do not** touch `apply_command`'s audited-command review checklist
  obligations beyond the new rows: the enabled setters bypass the ring
  entirely (direct atomics), so no `LE_CMD_*` codes are added — the plog-only
  table is the right home for 310–313.
