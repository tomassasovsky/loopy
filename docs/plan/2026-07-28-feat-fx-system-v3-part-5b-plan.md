---
title: "feat(control): FX interaction mode — three-way cycle, contextual stomps, LED projection"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Opus at high effort · `autonomy:merge-gate (physical slice blocked-verify)` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Add the third interaction mode — `InteractionMode.fx` — to the app's control
layer: the REC → MUTE → FX mode cycle, a zero-config contextual button layout
(track buttons stomp Track chains, Stop is FX panic, destructive buttons
inert), and chain-state LEDs projected app-side into the existing `trackLeds`
bytes so the wire and firmware grow nothing [R8]. This is the app half of the
epic's part 5; the wire-protocol half (v3 mode field, version discovery,
contract tests) is part 5a and must land first.

## Dependencies

Must be merged before this part starts:

- `docs/plan/2026-07-28-feat-fx-system-v3-part-5a-plan.md` — pedal protocol
  v3 wire: 2-bit state-frame mode field, on-pedal MODE LED indicator [A1],
  version discovery (unknown ⇒ encode v2, never v3 [R6]), v2/v1 projection
  [B10], contract-test hygiene [R9][R10][R11]. This part's `projectFrame`
  changes ride 5a's frame layout and version-downgrade path.
- `docs/plan/2026-07-28-feat-fx-system-v3-part-3a-plan.md` — domain model:
  `FxAddress {stage, index, lane?}`, per-effect + per-chain `enabled`,
  `looper_repository` four-stage chain APIs + enabled setters, `LooperBloc`
  Track/Master chain state ownership [VGV]. FX-mode stomps call these
  setters; LED projection reads this chain-enabled state.
- `docs/plan/2026-07-28-feat-fx-system-v3-part-1a-plan.md` — engine universal
  bypass: per-slot/per-chain atomic enabled flags + click-free ~5 ms
  crossfade on lane/monitor owners. The
  `le_engine_set_track_fx_chain_enabled` family this part's stomps
  ultimately drive lands in **part 1b** (reached transitively via part 3a's
  repository setters). Stomps are audible only because these exist.

## Context

Key files (line numbers verified in this worktree):

- `lib/looper/model/interaction_mode.dart:8-36` — `InteractionMode` is
  record | mute today; `fromToken` carries the legacy `'play'` → mute shim
  with an explicit "never remove without a stored-settings migration" doc
  contract. Extend, do not rewrite.
- `lib/control/cubit/control_cubit.dart` — `toggleMode()` two-value ternary
  at :210-213; `setMode` side-effect switch at :227-247; boot-default load at
  :158; the three mode-branch switch sites at :294, :383, :428; `_onPress`
  hard-wired button dispatch at :575-599. `ControlCubit` is the ONE
  control-surface interpreter (pinned cross-cutting decision — no second
  interpreter grows elsewhere).
- `lib/control/control_projection.dart:58-124` — `projectTrackLed` +
  `projectFrame` produce the all-8-track `trackLeds` bytes; the file's doc
  comment (:8) notes a sequence fuzzer checks the same spec — the fuzzer must
  learn the FX-mode projection too.
- `lib/looper/view/tracks_chrome.dart` — on-screen mode chip.
- `lib/looper/view/settings_page.dart` — default-mode settings picker.
- `lib/pedal/view/pedal_faceplate.dart:655,1002` — `_ledStateLabel` drives
  footswitch Semantics; today it is mode-blind.
- `lib/looper/view/tracks_commands.dart` +
  `lib/looper/view/shortcuts_help_sheet.dart` — keyboard digits 1-8 and the
  shortcuts help sheet (kept in sync by doc-comment contract).
- `lib/l10n/arb/app_en.arb` + `lib/l10n/arb/app_es.arb` — both ARBs, always.

Constraints lifted from the index (pinned — do not change):

- **[R8] No wire growth for chain-state LEDs.** FX-mode LEDs are produced
  app-side by `projectFrame` writing into the existing `trackLeds` bytes; a
  new `PedalTrackLed` color costs zero wire bytes; firmware track-LED
  rendering stays verbatim with no mode branch in either tree. With an older
  pedal the same projection code path runs — only the mode-field downgrade
  (part 5a) differs [B10].
- **[A5] Mode-cycle side effects fire on the landed mode only** — cycling
  through a mode must not fire its side effects. Entering FX mode while
  recording **finalizes the recording** (explicit, tested). MODE long-press
  stays performance-record arm.
- **[A2][A4] Every one of the 10 buttons is explicitly defined in FX mode.**
  The "focused track" default was rejected: focus has no on-pedal indicator,
  invisible targets get mis-stomped. A stray stomp must never erase the set.
- **[A3] Track buttons are bank-aware** — Track 1-4 target the active bank's
  tracks, exactly as in the other modes.
- **[R12] fx is excluded from the boot-default mode setting** — booting into
  FX with no chains is a dead surface.
- **[R24] Keyboard + a11y parity is part of the part, not a follow-up.**
- **[VGV] Safety claims need proof**: inert buttons get explicit negative
  `bloc_test`s.
- Stomp targets: FX-mode track buttons toggle **Track-stage chain enabled**
  (per-chain flag via the part-3a setters), not per-effect bits — per-effect
  and remapped bindings are part 6.

## Tasks

- [ ] **`InteractionMode.fx`** in `lib/looper/model/interaction_mode.dart`:
      third enum value with doc comment (track presses toggle Track chains);
      persisted token `'fx'`; `fromToken` shim extended — the legacy
      `'play'` → mute mapping and the unknown-token → record default stay
      byte-for-byte [R12].
- [ ] **Three-way cycle**: `toggleMode()` ternary (:210-213) becomes the
      REC → MUTE → FX → REC cycle. `setMode` (:227-247) gains the fx case;
      side effects fire only for the landed mode [A5].
- [ ] **Recording-finalize rule** [A5]: entering FX mode while recording
      finalizes the recording — explicit code path + `bloc_test`. MODE
      long-press unchanged (performance-record arm).
- [ ] **Boot-default exclusion** [R12]: the default-mode settings picker
      (`settings_page.dart`) never offers fx; `fromToken` on the stored
      default never resolves to fx for boot (defensive: a stored `'fx'`
      boot-default falls back to record). Widget test.
- [ ] **Mode chip / faceplate / settings picker updates** [R12]: mode chip in
      `tracks_chrome.dart` renders the FX state; `pedal_faceplate.dart`
      mirrors the MODE indicator tri-state introduced on-wire by part 5a;
      settings picker copy updated. Widget tests for all three.
- [ ] **All 10 buttons defined in FX mode** [A2][A4], dispatched from
      `ControlCubit`:
      - Track 1-4: toggle the active bank's tracks' **Track chain enabled**
        (bank-aware [A3]).
      - Bank: switches banks (unchanged).
      - Rec/Play: **inert, reserved** (focused-track idea dropped [A4]).
      - Stop: **FX panic** — all Track chains off; **long-press restores all
        back on**.
      - Undo: **inert until #219**.
      - Clear: **inert** — a stray stomp must never erase the set.
      - Mode: cycles; long-press = performance-record arm (unchanged).
      - Encoder: master gain (unchanged).
- [ ] **`ControlCubit` FX branches**: add `InteractionMode.fx` cases at the
      three switch sites (:294, :383, :428) and in `_onPress` (:575-599); no
      `default:` cases — exhaustive switches so the compiler flags gaps.
- [ ] **Button-matrix `bloc_test`s** [VGV]: explicit **negative** tests that
      Clear, Rec/Play, and Undo dispatch nothing in FX mode; Stop-panic +
      long-press-restore; bank-aware track toggles (bank B stomps bank B's
      tracks); recording-finalize on FX entry; landed-mode-only side effects.
- [ ] **Chain-state LED projection** [R8]: `projectFrame`
      (`control_projection.dart:82-124`) in FX mode writes Track-chain
      enabled state into the existing `trackLeds` bytes using the
      `PedalTrackLed` chain-state color added by part 5a — zero new wire
      bytes, no firmware mode branch. Extend the sequence fuzzer (doc
      contract at `control_projection.dart:8`) to the FX-mode spec.
- [ ] **Keyboard digits 1-8** [R24]: `tracks_commands.dart` gains the
      FX-mode interpretation (digit N toggles that track's Track chain), doc
      comment updated; `shortcuts_help_sheet.dart` updated in the same PR
      (the two are kept in sync by contract).
- [ ] **A11y** [R24]: `toggleMode()` announcement ternary gains
      `a11yModeFx`; `_ledStateLabel` (`pedal_faceplate.dart:1002`) labels
      LEDs **per active mode** so footswitch Semantics stay truthful (an FX
      LED reads as chain state, not record/mute state). Semantics tests.
- [ ] **Part-wide l10n** [R24][VGV]: every string this part introduces —
      mode chip FX label, `a11yModeFx`, per-mode LED labels, shortcuts-help
      rows, panic/restore descriptions, settings copy — lands in **both**
      ARBs (`app_en.arb` + `app_es.arb`). (The manual firmware-version
      setting strings ship with part 5a; the firmware-update banner is
      **this part's** — next bullet.)
- [ ] **"Pedal firmware update available" banner** [flow err-4]: when the
      connected pedal negotiates below v3, surface the banner wired to the
      #331 auto-detect/OTA flow; strings in both ARBs + Semantics.
- [ ] **Simulator/faceplate mirror**: the on-screen pedal simulator and
      faceplate render the mode indicator and FX-mode chain LEDs identically
      to the projection spec — simulator taps in FX mode dispatch the same
      contextual actions.
- [ ] **Mode-legibility test** [SC-1]: automated test (name contains "mode
      indicator") asserting that after any MODE sequence the projected frame
      (MODE LED tri-state + ring color + trackLeds) uniquely identifies the
      current mode — from LEDs alone a tester names the mode.
- [ ] **`blocked-verify` physical slice**: child issue (label
      `autonomy:blocked-verify`, #203 checklist pattern) for physical-pedal
      validation: mode cycle on hardware, FX LEDs on a v3 pedal, v2 pedal
      shows chain LEDs with mode projected as mute [B10].

## Success Criteria

```success-criteria
GOAL: A third pedal interaction mode (FX) with a safe, fully-defined contextual button layout and chain-state LEDs that ride the existing trackLeds projection — no wire growth, no destructive stray stomps.

SUCCESS CRITERIA:
- InteractionMode.fx exists; toggleMode cycles REC → MUTE → FX; persisted-token shim intact (legacy 'play' still maps to mute); fx excluded from boot default [R12] | verify: /Users/Tomas/development/flutter/bin/flutter test test/control --name "mode"
- Side effects fire on the landed mode only; entering FX while recording finalizes the recording [A5] | verify: /Users/Tomas/development/flutter/bin/flutter test test/control --name "mode"
- All 10 buttons defined: bank-aware track toggles, Stop = FX panic + long-press restore, Clear/RecPlay/Undo proven inert by negative bloc_tests [A2][A3][A4][VGV] | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- FX-mode trackLeds carry Track-chain enabled state via projectFrame; sequence fuzzer covers the FX spec; zero new wire bytes [R8] | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/pedal
- Keyboard digits 1-8 toggle Track chains in FX mode; shortcuts help in sync; a11yModeFx announced; _ledStateLabel truthful per mode; all new strings in both ARBs [R24] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper test/pedal
- Mode legibility: from LEDs alone the current mode is identifiable after any MODE sequence [SC-1] | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal --name "mode indicator"
- Physical pedal slice | verify: manual — blocked-verify child issue checklist (mode cycle on hardware; FX LEDs on v3 pedal; v2 pedal shows chain LEDs, mode projects as mute)

NON-GOALS:
- Wire protocol v3 itself — 2-bit mode field, MODE LED wire encoding, version discovery/#331, v2/v1 downgrade encoding, contract tests + golden .syx fixtures (part 5a)
- Per-button remap, momentary behavior, binding model, faceplate presentational extraction (part 6)
- Engine enabled flags, crossfade ramps, track bus (part 1a); domain enabled/slotId/envelope model (part 3a)
- Toggle undo/redo in FX mode before the #219 contract (part 9 coordinates; Undo stays inert here)
- Expression / MIDI CC control (part 7)
- Any new wire bytes for chain-state LEDs — rejected alternative, pinned [R8]

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test test/pedal test/control --name "mode"
```

## Notes

- **Dart-only part — no ffigen.** This part adds no native surface. If a
  dependency part's rebase retriggers binding regeneration, remember the repo
  gotcha: `dart format` after ffigen regen or the whole file churns.
- **cspell + semantic PR title before opening the PR**: the epic vocabulary
  (stomp, plog, FS-6, TRS) must be in the cspell dictionary, and the PR title
  must pass the semantic-title check — verify both before pushing, not after
  CI fails.
- **Stacked-PR squash landmines**: this part stacks on 5a → 3a → 1a. Squash
  merges break child merge-refs (CI silently absent) and API branch-deletes
  close children — rebase this branch onto its own parent's baseline after
  each upstream squash, per the repo discipline.
- **Screenshot goldens are author-machine-only**: the mode chip, settings
  picker, and faceplate changes will churn goldens; `test/screenshots` skips
  everywhere but the author's machine, so goldens rot silently — regen +
  eyeball locally as part of this PR.
- **Token shim is a contract**: `interaction_mode.dart`'s `fromToken` doc
  comment forbids removing the `'play'` legacy mapping without a
  stored-settings migration — add `'fx'` alongside, touch nothing else.
- **Exhaustive switches, no defaults**: adding the fx case to the mode
  switches without `default:` arms lets the compiler find every dispatch
  site; a `default:` would have silently swallowed the new mode.
- **Older pedals still enter FX mode** [B10]: the projection code path here
  is version-agnostic; only part 5a's mode-field downgrade differs. Do not
  branch this part's projection on pedal version.
- **PR contract**: `Closes #<child issue>` in the body; labels
  `stage:in-review`, the part's `autonomy:*`, `ci:*` + `review:pending`;
  mergeable only on CI green + `/code-review` clean (`ready-to-merge`).
