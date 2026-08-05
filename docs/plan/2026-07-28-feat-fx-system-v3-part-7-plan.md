---
title: "feat(midi): expression + external MIDI control (continuous + discrete CC)"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Opus at high effort · `autonomy:merge-gate` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Revive the dormant `controller_repository` layer into a real external-MIDI
control path: CC value passthrough with two trigger shapes — continuous CC
with LO/HI ranges driving parameters, and discrete on/off (threshold) CC
driving toggle/momentary bindings [A10] — sharing Part 6b's target model so
generic MIDI footswitches and the future Part 8 FS-6 work with zero extra
plumbing. Adds repo-side smoothing, global-only persistence via a
`controller.mappings` settings blob [R19], learn hygiene that ignores the
Segno pedal's own traffic [B8], and a fully specified MIDI-learn settings-tray
UI [R28].

## Dependencies

Must be merged first (this part stacks on them):

- `2026-07-28-feat-fx-system-v3-part-3a-plan.md` — `FxAddress` + canonical
  JSON serialization + stable per-slot `slotId`s [A9][R19] that mapping
  targets persist as; per-effect / per-chain `enabled` and param domain APIs
  the targets resolve against; the CI-gate fix that gives
  `packages/controller_repository` a CI job at all [VGV-critical]
- `2026-07-28-feat-fx-system-v3-part-6b-plan.md` — the **shared sealed target
  type + resolution in `lib/control/`** and the momentary release-all
  enforcement point in `ControlCubit` [B1] that discrete-CC bindings reuse

## Context

Key files:

- `packages/controller_repository/lib/src/controller_repository.dart` — the
  single controller-truth boundary. Today it is **press-only, discards CC
  values, has no UI callers, and no persistence of any kind**
  (`controller_repository.dart:66-89`, `controller_mapping.dart:82-90`)
  [R19]. Its learn flow exists but captures only presses
  (`controller_repository.dart:49-61`).
- `packages/controller_repository/lib/src/controller_mapping.dart` —
  `MappingTrigger` / `MappingEntry` / `ControllerMapping` (`resolve` drops
  non-press inputs at `controller_mapping.dart:82-90`); gains the new
  binding shapes and persisted forms.
- `lib/control/` — home of the typed sealed target + resolution (landed in
  Part 6b next to `ControlCubit`); `lib/control/cubit/control_cubit.dart` is
  the ONE control-surface interpreter and the single momentary release-all
  enforcement point [B1].
- `packages/settings_repository` — stores the one `controller.mappings` JSON
  blob (global-only) [R19].
- `lib/looper/view/settings_tray.dart` +
  `lib/looper/cubit/settings_tray_cubit.dart` — the settings tray whose
  pedal/audio sections the new MIDI-learn section matches [R28].
- `SignalKnob` / `signalMono` (`lib/looper/view/signal_graph/`) — the
  LO/HI row controls reuse these [R28].
- `docs/MIDI_FOOT_CONTROLLER.md` — stale today; refreshed here.

Constraints lifted from the index (pinned decisions — do not change):

- **Type ownership + dependency arrows [VGV-critical]:** mapping targets
  cross the `controller_repository` boundary as **canonical-JSON strings** —
  the package gains **no looper/engine dependency**. The typed sealed target
  + resolution live app-side in `lib/control/` (shared with Part 6b), and
  `ControlCubit` is the **single dispatch point for discrete-CC
  toggle/momentary interpretation — no second control-surface interpreter
  grows in a repository package**. Canonical `FxAddress` JSON is declared in
  Part 3a and referenced here, never redeclared [R19].
- **Persistence is global-only in v1** [R19] — rationale: expression
  hardware is per-rig, not per-song; sessions stay portable across machines.
  This is a deliberate divergence from Part 6b's per-session pedal bindings.
  Storage: one `controller.mappings` JSON blob in `settings_repository`.
- Target = FX param at `{FxAddress, slotId}`, track volume/pan, or master
  gain; effect-level targets go **inert (never retarget)** when the slotId
  is gone [A9].
- **Takeover = jump-on-first-move for v1** [B9]; pickup/catch is explicitly
  future work.
- Fan-out (one CC → many targets) is allowed — reference-grounded: Sheeran
  Looper X assigns up to 4 params to one expression pedal (manual 5.5.4);
  many CCs → one target = **last-writer-wins** [B8].
- **Release-all rule [B1] extends to MIDI-source disconnect** for momentary
  bindings — a held MIDI momentary + device unplug must release. Continuous
  bindings are the opposite: unplug mid-song = **value holds** [flow err-3].

## Tasks

- [ ] **CC value passthrough in `controller_repository`** [A10]: raw CC
      values flow through (today `resolve` drops everything that is not a
      press, `controller_mapping.dart:82-90`); two trigger shapes:
      - **Continuous**: `ContinuousBinding {trigger, target, lo, hi}` —
        absolute 0–127 CC mapped onto the target's LO/HI range
      - **Discrete on/off (threshold)**: CC crossing the threshold fires
        toggle or momentary behavior — same behavior vocabulary and target
        model as Part 6b, so generic MIDI footswitches and the Part 8 FS-6
        need zero extra plumbing
- [ ] **Smoothing on the repo side**: 7-bit CC steps → ramped param values
      (timer/ticker lives in the repository → it MUST be injectable/fake-
      clock-testable and disposed in `dispose()`)
- [ ] **Target registry** (as canonical-JSON strings at the repo boundary):
      FX param at `{FxAddress, slotId}` (Part 3a canonical form), track
      volume/pan, master gain — decoded app-side into the **shared sealed
      target type from Part 6b** in `lib/control/`
- [ ] **Persisted forms** [R19]: `MappingTrigger` and `ContinuousBinding`
      gain persisted forms (kind, CC id, MIDI channel, target via the Part 3a
      canonical FxAddress form, lo/hi); discrete bindings persist their
      threshold + behavior; everything serializes into the single
      `controller.mappings` JSON blob in `settings_repository`
      (global-only v1); load on startup, round-trips byte-stable
- [ ] **Learn hygiene** [B8]: MIDI-learn ignores the Segno pedal's own
      protocol traffic (its note range + relative encoder CC) so learning
      while the pedal is connected never captures pedal chatter; learn
      captures CC identity (kind, id, channel); fan-out allowed (one CC →
      many targets); many CCs → one target = last-writer-wins
- [ ] **Discrete-CC dispatch through `ControlCubit`** [VGV]: discrete
      toggle/momentary events dispatch through the same `ControlCubit`
      enforcement point as pedal bindings (per the ownership decision — no
      second interpreter in the repository); the **release-all rule [B1]
      extends to MIDI-source disconnect**: a held MIDI momentary releases
      (restores captured state) when its device unplugs
- [ ] **Takeover** [B9]: jump-on-first-move for v1 — first CC move sets the
      param to the mapped value immediately; no pickup/catch
- [ ] **Live behavior**: last-writer-wins between CC moves and UI knobs;
      unplug mid-song = continuous value **holds** (no snap-back);
      missing-device session/app load = mapping kept but **inert**, its UI
      row shows a device-missing state + one-tap relearn [flow err-3]
- [ ] **MIDI-learn UI** [R28]: a settings-tray section matching the existing
      pedal/audio sections; each mapping row = target picker + Learn button
      → "listening…" state with cancel + timeout; binding an already-bound
      CC replaces the old binding **after inline confirm**; LO/HI rows use
      `SignalKnob` + `signalMono`; device-missing rows render inert with the
      one-tap relearn action; l10n in BOTH ARBs + Semantics on rows, picker,
      Learn button, and LO/HI controls + widget tests [R24]
- [ ] **Repository-level tests enumerated [VGV]** (in
      `packages/controller_repository/test/`):
      - both trigger shapes resolve (continuous emits ranged values;
        discrete fires at threshold, both directions)
      - threshold semantics (crossing up fires, sitting on the boundary and
        jitter around it do not double-fire)
      - smoothing ramp: fake-clock tests for ramp trajectory + **timer
        disposal** (no pending timers after `dispose()`)
      - learn-ignores-pedal-traffic [B8]
      - fan-out (one CC drives all bound targets) + last-writer-wins (many
        CCs → one target)
      - persistence round-trip (blob → mappings → blob, byte-stable)
      - missing-device mapping stays inert (no events, no crash)
- [ ] **App-side tests** (`test/control`, `test/looper`): discrete-CC
      dispatch lands at the `ControlCubit` enforcement point; MIDI-disconnect
      releases held momentaries [B1]; hold-on-unplug for continuous;
      settings-tray section widget tests incl. listening/cancel/timeout,
      replace-confirm, and device-missing + relearn row [flow err-3][R28]
- [ ] **Refresh `docs/MIDI_FOOT_CONTROLLER.md`** (stale today): the two
      trigger shapes, LO/HI ranges, learn flow + hygiene, global-only
      persistence rationale, takeover rule, disconnect semantics

## Success Criteria

```success-criteria
GOAL: External MIDI control that a rig can rely on — learn a CC, sweep it, the mapped param moves through its LO/HI range, discrete CCs stomp like pedal buttons, and every mapping survives restart.

SUCCESS CRITERIA:
- Both trigger shapes resolve: continuous CC → ranged param values, discrete threshold CC → toggle/momentary [A10] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/controller_repository
- Smoothing ramp correct under fake clock; repository disposal leaves no pending timers | verify: /Users/Tomas/development/flutter/bin/flutter test packages/controller_repository
- Learn hygiene: pedal protocol traffic ignored; fan-out works; many-CCs-to-one-target is last-writer-wins [B8] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/controller_repository
- Persistence round-trip: controller.mappings blob (global-only) restores triggers, targets, lo/hi, thresholds byte-stable across restart [R19] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/controller_repository
- Missing-device mapping is inert, never crashes, and its row offers one-tap relearn [flow err-3] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/controller_repository test/looper
- Discrete-CC dispatch goes through the ControlCubit enforcement point; MIDI-disconnect releases held momentaries; continuous values hold on unplug [B1][VGV] | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- MIDI-learn settings-tray section: listening state with cancel/timeout, replace-after-confirm, SignalKnob LO/HI rows, l10n + semantics [R28][R24] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper

NON-GOALS:
- FxAddress, slotIds, canonical JSON declaration, enabled/param domain APIs — Part 3a owns them
- The sealed target type, pedal-button bindings, assignment screen, and the release-all enforcement point itself — Part 6b owns them (this part extends/reuses, never redeclares)
- TRS jack hardware, ladder decode, jack-type setting — Part 8 (it consumes this part's triggers over the existing cable)
- Engine bypass/ramp mechanics — Part 1
- MIDI clock, program change, pitch-bend/aftertouch; pickup/catch takeover (jump-on-first-move only [B9])
- Per-session expression mappings (global-only in v1, stated rationale [R19])

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test packages/controller_repository
```

## Notes

- **No native surface in this part** — no ffigen regen needed. If rebasing
  over engine parts that did touch native APIs, remember the repo gotcha:
  ffigen emits short-style and churns whole files; run `dart format` after
  any regen.
- **Before opening the PR**: check the cspell dictionary (relearn, lo/hi,
  FS-6, CC vocabulary) and the semantic PR title, not after CI fails.
- **Stacked-PR squash landmines**: this part stacks on 3a + 6b. Squash
  merges break child merge-refs (CI silently absent) and API branch-deletes
  close children; rebase this branch onto its own parent's baseline after
  each parent lands, per repo discipline.
- **testWidgets stream-cancel hang**: `await sub.cancel()` inline in a
  `testWidgets` body hangs forever (flutter/flutter#139870) — use
  `unawaited()` or `tearDown()`. Directly relevant here:
  `ControllerRepository.dispose()` awaits subscription cancels, and the
  disconnect-release tests exercise source streams.
- **Fake clock, not real sleeps**: the smoothing ramp timer must be
  injectable (`package:clock` / `fake_async` pattern) — the enumerated
  disposal + trajectory tests depend on it; never wall-clock-sleep in the
  package suite.
- **Goldens are author-machine-only**: if the settings-tray section touches
  screenshot goldens, regen + eyeball on the author machine; elsewhere they
  skip silently.
- The `packages/controller_repository` CI job lands with Part 3a's CI-gate
  fix [VGV-critical]; this part's suite is the merge gate — keep its
  `min_coverage` green.
