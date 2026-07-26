---
title: feat: Sheeran-style FX racks — part 1 (engine Pre/Post + Live Signal)
type: feat
date: 2026-07-26
issue: 351
part: 1
---

## feat: Sheeran-style FX racks — part 1 (engine Pre/Post + Live Signal) - Extensive

> Epic index: [2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md](2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md)
> Brainstorm: [docs/brainstorm/2026-07-26-sheeran-style-fx-racks-pre-post-brainstorm-doc.md](../brainstorm/2026-07-26-sheeran-style-fx-racks-pre-post-brainstorm-doc.md)
> Issue: [#351](https://github.com/tomassasovsky/loopy/issues/351)
> Branch: `feat/sheeran-style-fx-racks` (do **not** land on Control Center host-features)
> Autonomy: `autonomy:plan-gate` until **P1–P11** approved on #351; then `stage:build`

## Dependencies

None. First mergeable PR after plan-gate approval of epic defaults **P1–P11**.

## Overview

Land **true Pre bake** and **Post playback-only** in the native engine, plus
**Live Signal** monitor mixing (`Off` / `On` first; `Auto` once focus plumbing
exists in this PR). No Flutter UI in this part — C harness proves semantics.

Simplification from technical review: model **two chains per owner**
(`pre[]` + `post[]`) on each hardware input and each track — not an ordered list
of racks each tagged Pre/Post. UI “rack slots” with a Pre/Post toggle come in
part 3; they map to moving a chain between the two lists.

## Problem Statement

Recording always writes dry `insample`. FX only color monitor or playback. There
is no path to print delay into a take while keeping reverb editable on playback
(Sheeran Pre/Post).

## Proposed Solution

### Locked semantics (must match epic P1–P11)

| # | Rule |
|---|------|
| P1 | Live Signal On/Auto monitor path = **Pre → Post** |
| P2 | Record order: **Input Pre → Track Pre → buffer**; playback: buffer → **Track Post**; **Input Post** = live/FOH only (never prints) |
| P3 | Overdub: Pre reprints into write path; Post never enters PCM |
| P6 | Clear PCM keeps FX config (domain enforces later; engine must not wipe FX on clear) |
| P7 | Mid-record Pre param changes affect subsequent frames |
| P9 | **Track Pre/Post are sole track FX** until lane overrides; applied to every lane of that track. Pre = write-path; Post = playback-path (do not revive deleted `mon_fx` stage fields) |
| P11 | Live Signal **Auto** uses `le_engine_set_live_signal_focus(t)` — UI-selected monitoring focus, distinct from `primaryTrack` crown |

### Data model (native)

Per hardware input `c`:

- `fx_pre[LE_FX_MAX]`, `fx_post[LE_FX_MAX]` (+ counts)

Per track `t`:

- `fx_pre[]`, `fx_post[]`, `live_signal` ∈ {`OFF`,`AUTO`,`ON`}
- Shared by all lanes of `t` (P9)

Compat shims (keep Dart alive until part 2):

- `le_engine_set_monitor_input_fx*` → write **Input Post** chain
- `le_engine_set_lane_fx*` → write **Track Post** for that track (lane index ignored for ownership; still apply on that lane’s playback until track-level state is fully wired — prefer writing track Post and copying to all lanes)

New API (names illustrative — finalize in `loopy_engine_api.h`):

- `le_engine_set_input_fx_pre/post`, counts, params
- `le_engine_set_track_fx_pre/post`, counts, params
- `le_engine_set_track_live_signal(t, mode)`
- `le_engine_set_live_signal_focus(t)` — selected track for **Auto** (UI/repo will push; part 1 tests set it directly)

### Process path (`engine_process.c`)

1. **Record/overdub write:**  
   `wet = InputPre(assigned_input, clean); wet = TrackPre(track, wet);` store `wet`.
2. **Playback:** `out = TrackPost(track, buffer_sample);` route.
3. **Live Signal monitor** (per track, summed when multiple On — P5 soft-cap later):
   - Off: no track FX into monitor mix (Input Post still follows input monitor enable)
   - On: monitor `Pre→Post` of that track’s assigned input always
   - Auto: same as On only when `live_signal_focus == track`

### Implementation tasks

- [ ] Confirm **P1–P11** on #351 (human) before coding
- [ ] Prefer landing **compat shims only** in this PR if Dart AudioEngine cannot
      be updated in the same PR; otherwise land ffigen + minimal AudioEngine
      setters so master Dart is not half-broken
- [ ] Extend `engine_private.h` / `engine_fx.*` for input+track pre/post chains
- [ ] Wire Pre into record/overdub write in `engine_process.c`
- [ ] Wire Post on playback; Input Post on input monitor path
- [ ] Live Signal Off/On/Auto + `set_live_signal_focus`
- [ ] Compat shims for existing monitor/lane FX setters → Post
- [ ] Update `loopy_engine_api.h`; run ffigen + format bindings if this PR exposes new symbols to Dart (prefer shim-only Dart surface in part 1 if possible)
- [ ] Add named cases in `packages/loopy_engine/src/test/test_engine_core.c`:
  - `pre_bake_delay`
  - `post_never_bakes`
  - `live_signal_off_still_prints`
  - `live_signal_auto_on`
  - `pre_overdub_reprints` (basic)
- [ ] Document temporary dual API in `docs/PROGRESS.md` FX section (brief)

## Technical Considerations

- **Architecture:** Engine remains pure sink; no UI selection ownership in C beyond focus channel setter.
- **Performance:** Extra `fx_apply_chain` on record path — same DSP cost as today’s playback; watch RT budget.
- **Security:** N/A.
- **Caps:** Keep `LE_FX_MAX` per chain (pre and post each up to max), not a single shared pool, unless RT forces otherwise — document choice in API comments.

## Success Criteria

```success-criteria
GOAL: Native engine prints Pre FX into the record/overdub buffer, applies Post only on playback, and mixes Live Signal Off/On/Auto correctly.

SUCCESS CRITERIA:
- Named Pre/Post/Live Signal cases pass in the core harness | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- pre_bake_delay: recording with Pre delay (Post empty) stores wet buffer content distinct from dry control | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- post_never_bakes: Post-only reverb leaves recorded buffer matching dry control within harness tolerance | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- live_signal_off_still_prints: Live Signal Off omits track FX from monitor while Pre still bakes | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- live_signal_auto_on: Auto monitors only when focus track matches; On monitors regardless | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Compat: existing set_monitor_input_fx / set_lane_fx still compile and map to Post chains (no Dart UI required) | verify: bash packages/loopy_engine/src/test/run_native_tests.sh

NON-GOALS:
- Flutter FX page, presets, session migration, daw_export
- Pedal/expression, Bounce As Loop, per-lane overrides
- Factory rack content
- Soft CPU warnings for multi Live Signal On (part 5)

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh
```

## Success Metrics

- All new named cases green in `run_native_tests.sh`
- No regression in existing engine core suite

## Dependencies & Risks

- Plan-gate on #351 (P1–P11)
- Risk: undoing Pre-baked overdub layers — cover basic overdub reprint; full undo contracts in part 5
- Risk: multi-input routing — record uses the lane’s **assigned** hardware input for Input Pre only

## References & Research

- Epic: `docs/plan/2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md`
- `packages/loopy_engine/src/core/engine_process.c`, `engine_fx.c`, `loopy_engine_api.h`
- `packages/loopy_engine/src/test/run_native_tests.sh`, `test_engine_core.c`
- `docs/PROGRESS.md` (native test runner / ffigen notes)
- Sheeran Pre/Post + Live Signal: HeadRush support article + Looper X user guide (linked in epic)
