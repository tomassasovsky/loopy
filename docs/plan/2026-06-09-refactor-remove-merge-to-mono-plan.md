---
title: Remove the "merge to mono" feature
type: refactor
date: 2026-06-09
---

## Remove the "merge to mono" feature - Standard ♻️

> Source brainstorm: [docs/brainstorm/2026-06-09-remove-merge-to-mono-brainstorm-doc.md](../brainstorm/2026-06-09-remove-merge-to-mono-brainstorm-doc.md)

## Overview

Delete the **merge to mono** feature end to end. It was a global engine mode
that averaged all hardware inputs to a single mono value and fed that value to
every output channel. With per-track I/O routing now in place — each track owns
a mono buffer, an `inputMask` (the hardware inputs it records, averaged to
mono), and an `outputMask` (the hardware outputs it plays to) — the concept is
redundant for recording and playback and survived only as a monitoring hack.

This change removes the config flag, the native engine field, the FFI struct
member (regenerated, not hand-edited), the two Dart config models, the persisted
key, the cubit/state surface, the setup UI toggle and "Ready" summary row, and
the `audio_bootstrap` wiring. Live input monitoring reverts to a plain
**channel-matched passthrough** (input channel `c` → output channel `c`).

This is a deletion-shaped refactor with strong local context; no external
research was required.

## Problem Statement / Motivation

A track is **mono by construction**, so "mono vs stereo" is now purely a
**routing outcome**, not a global mode:

- **Recording:** each track already records the average of its `inputMask`
  channels into its mono buffer. Merge-to-mono added nothing here — worse, it
  *bypassed* the per-track mask (the source of the bug fixed in `d85eb46`,
  "honor per-track input mask in mono-input mode").
- **Playback:** the mono track plays to every channel in its `outputMask`
  (default `0x3` = both). A mono instrument on input 1 is already heard on L&R
  on the recorded loop, with no switch.
- **Monitoring (live passthrough):** the only place the flag still did anything.
  It summed inputs across all outputs so a mono source wasn't stuck on L.

Keeping the toggle conflates *input-folding* with *mono→stereo spread*, both of
which routing already expresses. The user opted to drop the feature entirely
rather than re-implement monitoring to follow the selected track's routing:
interfaces commonly provide zero-latency hardware direct monitoring, and routing
already covers the recorded result. Monitoring therefore reverts to a simple,
honest channel-matched passthrough.

## Proposed Solution

Remove every `merge_to_mono` / `mergeToMono` / `mono_input` surface, and
simplify the engine's monitor line to a channel-matched passthrough. Work
bottom-up (native → FFI regen → Dart libs → app → tests) so the FFI struct
agreement is re-established before the Dart side is touched.

### What is explicitly **kept** (out of scope)

- The **`monitorInput` on/off toggle** (`audioSetup_monitor_switch`) — a
  separate, still-meaningful control.
- Tracks stay **mono**; no stereo-buffer work. A true stereo source is captured
  with two tracks (in1→out1, in2→out2). This expectation is documented, not
  coded.

## Technical Considerations

- **FFI struct agreement.** `merge_to_mono` is a field of the `le_config`
  (`LeConfig`) struct in `loopy_engine_api.h`. The Dart bindings in
  `lib/src/generated/loopy_engine_bindings.dart` are **ffigen-generated**
  (`ffigen.yaml` present; file header says *AUTO GENERATED, DO NOT EDIT*).
  Delete the field from the header, then **regenerate** — do not hand-edit the
  bindings. Run from `packages/loopy_engine`:

  ```bash
  dart run ffigen --config ffigen.yaml
  ```

  Confirm the regen drops `external int merge_to_mono;` and leaves the rest of
  the struct byte-compatible with `EngineConfig.toNative`.

- **Native monitor simplification.** In `engine.c`, the per-frame monitor line
  currently reads:

  ```c
  out[f * ch_out + c] += e->mono_input ? mono : (in ? in[f * ch_in + c] : 0.0f);
  ```

  Drop the `mono_input ? mono :` branch so it becomes a plain passthrough. With
  that gone, the per-frame `mono` accumulator (`engine.c:509`, `:521`, `:523`)
  is dead — remove the local, the `mono += s;` line, and the `mono /= …;` fold.
  `active_in` must **stay** (still used at `engine.c:784` for `total_in`).

- **Performance.** Net positive / neutral: one fewer branch and one fewer
  divide per frame in the RT path. No allocations changed.

- **Persistence is backward-compatible.** Dropping the `audio.merge_to_mono`
  store key means an old persisted bool is simply never read on load. No
  migration, no version bump needed.

- **Restore path.** `merge_to_mono` is not persisted on the native side; it only
  ever arrived via `le_config` at configure time. Removing it from the struct +
  regen + rebuild is sufficient (resolves the brainstorm's first open question).

## Implementation Plan (file-by-file)

Ordered so each layer compiles before the next depends on it.

### Phase 1 — Native engine (C)

- [ ] `packages/loopy_engine/src/loopy_engine_api.h:117` — delete the
      `int32_t merge_to_mono;` struct member (and its comment).
- [ ] `packages/loopy_engine/src/engine.c`:
  - [ ] Delete the `int mono_input;` field (`:165`).
  - [ ] Delete the per-frame `mono` accumulator: `float mono = 0.0f;` (`:509`),
        `mono += s;` (`:521`), and `mono /= (float)(active_in > 0 …);` (`:523`).
  - [ ] Simplify the monitor line (`:702`) to:
        `out[f * ch_out + c] += in ? in[f * ch_in + c] : 0.0f;`
  - [ ] Update the capture-loop comment block (`:632–636`) that references
        "mono-input mode" / "merge to mono" to reflect that the mask is simply
        always honored (no mode left to contrast against).
  - [ ] Delete `le_engine_set_mono_input_for_test` (`:1174–1177`).
  - [ ] Delete `engine->mono_input = config->merge_to_mono ? 1 : 0;` (`:1224`).
- [ ] `packages/loopy_engine/src/engine_internal.h:52–55` — delete the
      `le_engine_set_mono_input_for_test` declaration and its doc comment.
- [ ] `packages/loopy_engine/src/test/test_engine_core.c`:
  - [ ] Remove or repurpose `test_routing_input_mask_honored_in_mono_mode`
        (`:1094–1133`). The mask-honoring guarantee it asserts is now covered by
        the always-on mask path — fold its two assertions (single-channel mask
        records that channel; empty mask records silence) into the existing
        `test_routing_input_mask*` tests rather than deleting coverage outright.
        Drop the two `le_engine_set_mono_input_for_test(...)` calls (`:1111`,
        `:1124`).
  - [ ] Remove the `test_routing_input_mask_honored_in_mono_mode();`
        registration in `main()` (`:1160`).

**Gate:** native `ALL PASSED`.

### Phase 2 — FFI regen

- [ ] Regenerate bindings: `cd packages/loopy_engine && dart run ffigen --config
      ffigen.yaml`.
- [ ] Verify `lib/src/generated/loopy_engine_bindings.dart:817`
      (`external int merge_to_mono;`) is gone and the diff is limited to that
      field (and any struct size/offset metadata ffigen emits).

**Gate:** struct agreement (regen diff is field-scoped, nothing else churned).

### Phase 3 — Dart libraries

- [ ] `packages/loopy_engine/lib/src/engine_config.dart` — remove
      `mergeToMono` from: the constructor param (`:21`), the field (`:53`), the
      `..merge_to_mono = …` line in `toNative` (`:78`), `operator ==` (`:95`),
      `hashCode` (`:108`), and `toString` (`:120`).
- [ ] `packages/settings_repository/lib/src/settings_repository.dart` — remove
      from `StoredAudioConfig`: constructor (`:13`), field (`:30`),
      `operator ==` (`:52`), `hashCode` (`:63`); delete the
      `_audioMergeToMonoKey` const (`:123`); drop the `mergeToMono:` read in the
      load path (`:139`) and the `setBool(_audioMergeToMonoKey, …)` write
      (`:152`).

### Phase 4 — App wiring & UI

- [ ] `lib/audio_setup/cubit/audio_setup_state.dart` — remove the field default
      (`:37`), field (`:59`), `copyWith` param + assignment (`:108`, `:123`),
      and the `props` entry (`:142`).
- [ ] `lib/audio_setup/cubit/audio_setup_cubit.dart` — delete `setMergeToMono`
      (`:68–69`); remove `mergeToMono:` from the `EngineConfig` build (`:122`)
      and the `StoredAudioConfig` build (`:133`); remove the hydration branch
      (`:269–271`).
- [ ] `lib/audio_setup/view/audio_setup_steps.dart` — delete the entire
      "Merge to mono" `_Toggle` block (`:229–235`) **and** the now-orphaned
      `SizedBox(height: 12)` spacer (`:228`) that separated it from the Monitor
      toggle; remove the `('Merge to mono', …)` row from the "Ready" summary
      table (`:260`).
- [ ] `lib/app/audio_bootstrap.dart:22` — remove `mergeToMono: saved.mergeToMono`
      from the config it assembles.

### Phase 5 — Update tests

- [ ] `packages/loopy_engine/test/engine_config_test.dart` — drop the
      `mergeToMono` default assertion (`:18`), the constructor arg (`:33`), and
      the `ptr.ref.merge_to_mono` struct assertion (`:47`).
- [ ] `packages/settings_repository/test/settings_repository_test.dart` — remove
      `mergeToMono:` from the four `StoredAudioConfig` fixtures (`:162`, `:173`,
      `:196`, `:225`). Add/keep a case proving an **old persisted
      `audio.merge_to_mono` bool is ignored on load** (backward-compat:
      pre-seed the fake store with that key and assert load succeeds and the key
      is untouched).
- [ ] `test/app/audio_bootstrap_test.dart` — remove the `mergeToMono:` args and
      the `engine.lastConfig?.mergeToMono` assertion (`:40`, `:81`, `:95`,
      `:108`, `:138`, `:173`, `:190`).
- [ ] `test/audio_setup/cubit/audio_setup_cubit_test.dart` — delete the
      `mergeToMono` default/state assertions and the `setMergeToMono` act/expect
      (`:51`, `:80`, `:91`, `:100`, `:121`, `:198`).
- [ ] `test/audio_setup/view/audio_setup_view_test.dart` — delete the
      `audioSetup_mergeToMono_switch` tap + `setMergeToMono` verify (`:76–77`).
      Add an assertion that the toggle is **absent**
      (`find.byKey(const Key('audioSetup_mergeToMono_switch'))` is
      `findsNothing`).

## Acceptance Criteria

- [ ] No source reference to `merge_to_mono`, `mergeToMono`, `mono_input`,
      `setMergeToMono`, or `audioSetup_mergeToMono_switch` remains anywhere
      (verify: the project-wide grep used in research returns nothing in
      non-test and test code alike).
- [ ] `loopy_engine_api.h` no longer declares `merge_to_mono`; regenerated
      bindings reflect the removal and were produced by ffigen (not hand-edited).
- [ ] Native test suite prints `ALL PASSED`; the mask-honoring guarantees
      (single-channel mask → that channel; empty mask → silence) remain covered
      by the always-on mask tests.
- [ ] Live monitoring routes input `c` → output `c` for shared, non-excluded
      channels; excluded/loopback channels remain unmonitored.
- [ ] The audio-setup wizard shows **only** the "Monitor input" toggle in that
      step; the "Ready" summary no longer lists a "Merge to mono" row; vertical
      spacing has no orphaned gap.
- [ ] Loading a settings store that still contains an `audio.merge_to_mono` key
      succeeds and ignores the value (no crash, no migration).
- [ ] `flutter analyze` is clean; full app + package test suites pass; macOS
      build succeeds.

## Edge Cases & Flow Notes

- **Backward compat on load.** A user upgrading from a build that persisted
  `audio.merge_to_mono` must load cleanly — the key is silently ignored. Covered
  by an explicit settings-repository test (above).
- **Layout regression.** Removing the second `_Toggle` must not leave a dangling
  `SizedBox` spacer or change the Monitor toggle's position unexpectedly —
  remove the paired spacer and assert toggle absence in the widget test.
- **Behavior change for mono sources while monitoring.** A mono source on input
  1 is now monitored only on output 1 (was: both). This is the intended,
  documented trade-off — hardware direct monitoring or two-track routing covers
  the stereo case. Worth a one-line note in `docs/PROGRESS.md` so the behavior
  change is discoverable.
- **Comment hygiene.** Several native comments narrate the now-removed mode
  (`engine.c:632–636`, the test's docstring). Leaving them would mislead; update
  them as part of the same change.

## Success Metrics

- Net negative diff (more deletions than additions) outside of test
  restructuring.
- One fewer branch + one fewer divide in the per-frame RT monitor path.
- Zero behavioral regressions in recording/playback routing (existing routing
  tests stay green unchanged).

## Dependencies & Risks

- **ffigen availability** in the dev environment is required for Phase 2.
  Low risk — `ffigen.yaml` already exists and the bindings are generated today.
- **Test-runner gotcha:** the `very_good` MCP test path is unreliable in this
  repo; run package/app tests with the absolute Flutter path per project memory.
- **Struct churn risk:** if ffigen reorders or re-emits unrelated struct
  metadata, scrutinize the bindings diff so the only semantic change is the
  dropped field. Mitigation: review the regen diff before committing.
- **Coverage-loss risk:** deleting `test_routing_input_mask_honored_in_mono_mode`
  outright would drop the empty-mask-records-silence assertion. Mitigation: fold
  those assertions into the surviving mask tests rather than removing them.

## References & Research

- Brainstorm: [docs/brainstorm/2026-06-09-remove-merge-to-mono-brainstorm-doc.md](../brainstorm/2026-06-09-remove-merge-to-mono-brainstorm-doc.md)
- Native monitor line: [packages/loopy_engine/src/engine.c:702](../../packages/loopy_engine/src/engine.c)
- Per-frame `mono` fold: [packages/loopy_engine/src/engine.c:509](../../packages/loopy_engine/src/engine.c)
- FFI struct field: [packages/loopy_engine/src/loopy_engine_api.h:117](../../packages/loopy_engine/src/loopy_engine_api.h)
- Generated binding: [packages/loopy_engine/lib/src/generated/loopy_engine_bindings.dart:817](../../packages/loopy_engine/lib/src/generated/loopy_engine_bindings.dart)
- Test helper decl: [packages/loopy_engine/src/engine_internal.h:52](../../packages/loopy_engine/src/engine_internal.h)
- Setup UI: [lib/audio_setup/view/audio_setup_steps.dart:229](../../lib/audio_setup/view/audio_setup_steps.dart)
- Related prior fix: commit `d85eb46` — "honor per-track input mask in
  mono-input mode" (the bug that motivated this removal).
- Related plan: [docs/plan/2026-06-09-feat-multichannel-routing-plan.md](2026-06-09-feat-multichannel-routing-plan.md)
