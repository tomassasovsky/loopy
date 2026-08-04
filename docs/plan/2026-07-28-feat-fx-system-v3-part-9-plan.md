---
title: "chore: hardening, export replay, appliance soak, docs"
type: chore
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Opus at medium effort · `autonomy:blocked-verify` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Close out FX system v3: teach `daw_export`'s reader side the new Track/Master
stages (the writer/model side landed in Part 3b), prove mid-capture stomps
survive into rendered wet stems via a plog replay test [R3], soak the wet
cache on the Pi appliance (hit-rate, xrun budget, load-storm ordering, cap
tuning) [B6][flow SC-7], surface the cache debug glyph behind the existing
indicator toggle [R27], write the toggle undo/redo contract with #219, and
rewrite the FX mental model in `docs/PROGRESS.md` plus release notes.

## Dependencies

Must be merged first (this part stacks on the whole epic):

- `2026-07-28-feat-fx-system-v3-part-0-plan.md` — arm() fix groundwork
- `2026-07-28-feat-fx-system-v3-part-1a-plan.md` — universal enable + ramp +
  plog enabled events + `perf_render` replay of the new codes [R3]
- `2026-07-28-feat-fx-system-v3-part-1b-plan.md` — track bus + master insert
- `2026-07-28-feat-fx-system-v3-part-2-plan.md` — loop-stage wet cache,
  telemetry (log/test-only until this part), configurable memory cap,
  playing-lanes-first worker [B6]
- `2026-07-28-feat-fx-system-v3-part-3a-plan.md` — `FxAddress`/slotIds/
  enabled domain model + CI jobs
- `2026-07-28-feat-fx-system-v3-part-3b-plan.md` — session v5 migration +
  **manifest stages writer** (`PerformanceChains`/armSnapshot track/master
  fields + presence-keyed version marker + enabled bits [R20][R3])
- `2026-07-28-feat-fx-system-v3-part-4a-plan.md` /
  `2026-07-28-feat-fx-system-v3-part-4b-plan.md` — four-stage Signal
  surface (lane cards the debug glyph attaches to)
- `2026-07-28-feat-fx-system-v3-part-5a-plan.md` /
  `2026-07-28-feat-fx-system-v3-part-5b-plan.md` — FX mode incl. the
  "Undo inert until #219" negative tests this part's contract preserves
- `2026-07-28-feat-fx-system-v3-part-6a-plan.md` /
  `2026-07-28-feat-fx-system-v3-part-6b-plan.md` — pedal remap + momentary
  (soak exercises stomp churn)
- `2026-07-28-feat-fx-system-v3-part-7-plan.md` — expression (soak exercises
  bound-param sweeps against the render debounce)
- `2026-07-28-feat-fx-system-v3-part-8-plan.md` — TRS jack hardware; per the
  epic's pinned scheduling note it is a `blocked-verify` child issue,
  **dependent on — not gating — the epic's close**; this part consumes none
  of its surface and does not wait on its bench validation.

## Context

Key files:

- `packages/daw_export/lib/src/manifest_reader.dart` — armSnapshot parsing;
  gains Track/Master stage + enabled-bit reading (presence-keyed, per the
  Part 3b version marker [R20]).
- `packages/daw_export/lib/src/fx_chains.dart` — generates `fx-chains.txt`
  from armSnapshot lane effects; gains Track/Master sections.
- `packages/daw_export/lib/src/event_log_reader.dart` + tests and
  `packages/daw_export/test/corpus/` — fixtures need a manifest with the new
  stages and mixed enabled bits; legacy fixtures must keep parsing.
- `packages/segno_engine/src/test/test_engine_core.c` +
  `packages/segno_engine/src/test/run_native_tests.sh` — home of the
  mid-capture stomp replay test (Part 1a wired `perf_render`'s per-frame
  switch to replay the enabled plog codes).
- `docs/design/performance-event-log-format.md` — audit table with a verdict
  row per command (Part 1a added the enabled events; track/master setters
  are **manifest-only, "No replay" with rationale** — pinned) [R3].
- `docs/RUNNING_ON_RPI.md` — arm64 bundle build steps, on-device bring-up
  checklist pattern; the soak report and documented limits land here.
- `lib/looper/cubit/tracks_cubit.dart:42-57` /
  `lib/looper/cubit/tracks_state.dart:29` (`showIndicators`),
  `lib/looper/view/settings_page.dart:129-161` (the toggle),
  `lib/looper/view/track_column.dart:300` (consumer) — the **existing
  debug/indicator toggle** the cache glyph rides [R27].
- `docs/PROGRESS.md` — FX mental-model rewrite target.

Constraints lifted from the index (pinned decisions — do not change):

- **Stems decision stands [R20]:** Track/Master chains go **in the
  manifest, not rendered into stems** — stems stay per-stage
  dry-of-downstream. The reader renders the stages; it never bakes them.
- **Track/master setters have no plog replay** — manifest-only, recorded as
  "No replay" rows with rationale in the audit table [R3]. Only lane
  (loop-stage) enabled events replay in `perf_render`.
- Arm manifest carries enabled bits so `le_pr_fx_chain_init_from_lane`
  seeds arm-time state [R3] (writer landed in Part 3b).
- Cache soak targets: single worker, **playing-lanes-first** priority [B6];
  session-load render storm must stay xrun-free [flow SC-7]; memory cap is
  configurable and **appliance-tuned here**.
- Cache telemetry (live | cached | rendering | failed-retrying | gave-up)
  is log/test-only in v3; the **debug glyph is the only UI surface and it
  hides behind the indicator toggle** — kept out of the calm default UI
  [R27].
- **Toggle undo/redo is NOT implemented here**: undo stays inert in FX mode
  per Part 5b until the #219 contract lands (epic non-goal).
- Disabled/dim styling uses `SurfaceTheme` tokens, no ad-hoc opacity
  constants [VGV].

## Tasks

- [ ] **`daw_export` reader: Track/Master stages** [R20]:
      `manifest_reader.dart` parses the Part 3b armSnapshot track/master
      chain fields + per-slot/per-chain enabled bits, presence-keyed so
      pre-v3 manifests (no marker) still parse with empty new stages;
      `fx_chains.dart` renders Track and Master sections in
      `fx-chains.txt` after the per-lane sections, marking disabled slots
      and disabled chains; decision restated in the reader's doc comment:
      chains in manifest, **not** in stems
- [ ] **Corpus + tests**: add a corpus manifest fixture with track/master
      stages and mixed enabled bits; keep a legacy fixture green
      (back-compat proof); extend `manifest_reader_test.dart` +
      `fx_chains_test.dart` for the new sections, enabled rendering, and
      the presence-keyed fallback
- [ ] **Mid-capture stomp export replay test** [R3] (native,
      `test_engine_core.c`): arm → play a loop-stage chain → toggle a slot
      mid-capture (plog `LE_PLOG_SET_LANE_FX_ENABLED`) → `perf_render`'s
      wet stem flips wet↔bypassed at the logged frame (within the Part 1a
      ramp window); chain-level twin
      (`LE_PLOG_SET_LANE_FX_CHAIN_ENABLED`) covered; **a slot disabled at
      arm renders bypassed throughout** (manifest enabled bits seed
      `le_pr_fx_chain_init_from_lane`)
- [ ] **Audit table final pass** [R3]: every command added by the epic has
      a verdict row in `docs/design/performance-event-log-format.md`;
      track/master setter rows read "No replay" with the manifest-only
      rationale — verify, don't re-litigate
- [ ] **Appliance soak** (manual, Pi console, arm64 bundle per
      `docs/RUNNING_ON_RPI.md`):
      - full 8-track set with loop-stage chains: measure **cache hit-rate**
        from Part 2 telemetry logs and steady-state CPU; count xruns over a
        timed session and state the budget the numbers meet
      - **session-load render storm**: load the 8-track set cold → all
        lanes re-render; confirm playing lanes render **first** [B6] and
        playback stays xrun-free during the storm [flow SC-7]
      - stomp churn + expression sweeps: toggled-pair retention keeps
        off/on cache-hot [B2]; continuous sweeps hold the render debounce
        (no schedule thrash) — observe and note
      - **cap tuning**: pick the appliance default for the cache memory
        cap; record value + rationale
      - write the soak report + documented limits (cached-lane count,
        memory, render latency) into `docs/RUNNING_ON_RPI.md` following
        its on-device checklist pattern
- [ ] **Cache debug glyph** [R27]: per-lane cache state glyph
      (live | cached | rendering | failed-retrying | gave-up) on lane
      cards, sourced from the Part 2 snapshot telemetry, rendered only
      when `showIndicators` is on (`tracks_state.dart:29`); `SurfaceTheme`
      tokens only [VGV]; Semantics label + l10n in both ARBs; widget tests
      for visibility gating and each state; if the telemetry needs a
      Dart-visible field beyond Part 2's log/test surface, add the minimal
      binding (ffigen regen + `dart format`)
- [ ] **Undo/redo coordination with #219**: write the toggle undo/redo
      contract as a design note on #219 (granularity of stomp undo,
      interaction with momentary capture/restore [B1], note that toggles
      never bump `a_audio_rev` so cache keys are unaffected); FX-mode undo
      **stays inert** — Part 5b's negative tests remain the guard; no
      implementation in this part
- [ ] **`docs/PROGRESS.md` FX mental-model rewrite**: four stages, capture
      always dry + inheritance as by-value copy with provenance [A6][R13],
      auto-cache ("when in doubt, play live"), universal bypass, pedal FX
      mode, expression mapping; refresh the build/test pointers it anchors
- [ ] **Release notes**: session v4→v5 migration defaults, overdub
      never re-inherits [A7], **D-TRACKROUTE divergent-mask behavior
      change** (union rule engages only when track FX added), no tail
      spill on bypass [B7], cache fallback drops tails at the edit instant
      [B4] and the mute-during-cached-playback difference [R5]

## Success Criteria

```success-criteria
GOAL: The v3 epic is hardened and closable — exports understand all four stages, stomps replay into wet stems, the cache holds up on the appliance under real load, and the docs describe the system that shipped.

SUCCESS CRITERIA:
- daw_export reader renders Track/Master stages (fx-chains.txt + manifest reader) with enabled bits, presence-keyed back-compat; chains in manifest, never baked into stems [R20] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/daw_export
- Mid-capture stomp replay: rendered wet stem flips at the logged frame; slot disabled at arm renders bypassed; chain-level twin covered [R3] | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Appliance soak: cache hit-rate + xrun budget under a full 8-track set; session-load render storm xrun-free with playing-lanes-first ordering [B6][flow SC-7]; cap tuned + limits documented | verify: manual xrun/cache-hit soak report on Pi console per docs/RUNNING_ON_RPI.md
- Cache debug glyph shows all five telemetry states, only when the indicator toggle is on; hidden in the calm default UI [R27] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper
- Undo/redo contract posted on #219; FX-mode undo still inert (Part 5b negative tests green); PROGRESS.md rewrite + release notes merged | verify: manual — #219 comment linked in the PR body, docs reviewed in-diff

NON-GOALS:
- plog event emission and perf_render replay wiring — Part 1a owns them; this part only adds the end-to-end flip test
- Cache implementation, telemetry plumbing, cap mechanism — Part 2 (this part tunes the cap value and surfaces the glyph)
- Manifest/armSnapshot WRITER side and enabled-bit seeding — Part 3b
- Implementing toggle undo/redo — #219 owns it
- TRS jack bench validation — Part 8's own blocked-verify checklist
- Caching Input/Track/Master stages, plugin-bearing chains, or any new engine/UI features

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test packages/daw_export
```

## Notes

- **The soak slice is device-gated**: CI cannot verify it ("green in CI" is
  not "works on the Pi"). The code-bearing changes (reader, replay test,
  glyph, docs) merge on CI + review; the soak report is a manual
  deliverable attached before the epic closes. Label judgment per
  docs/TRACKING.md — escalate rather than merge an untested soak claim.
- **ffigen regen + `dart format`**: only needed if the glyph requires a new
  Dart-visible telemetry field; ffigen emits short-style and churns whole
  files — always `dart format` after regen.
- **Before opening the PR**: check the cspell dictionary (xrun, soak, plog,
  stomp vocabulary) and the semantic PR title, not after CI fails.
- **Stacked-PR squash landmines**: this part lands last on a long stack.
  Squash merges break child merge-refs (CI silently absent) and API
  branch-deletes close children — rebase onto this branch's own parent
  baseline after each parent lands.
- **Goldens are author-machine-only**: the lane-card glyph touches tracks
  screenshots — regen + eyeball on the author machine; elsewhere they skip
  silently and rot.
- The native replay test builds via the hand-authored FFI plugin tooling —
  see `docs/PROGRESS.md` "How to build / test" for the macOS dylib gotchas
  before touching `run_native_tests.sh`.
- `fx_chains.dart` documents that effects only ever appear on armSnapshot
  lane entries (`docs/design/performance-manifest-format.md`) — the new
  track/master fields extend that doc in the same PR as the reader.
