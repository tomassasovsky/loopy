---
title: "feat(pedal): FX remap bindings, momentary, assignment screen"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Opus at high effort · `autonomy:merge-gate` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Add optional per-session pedal remapping on top of Part 5b's contextual FX
mode: a binding model `{(button, bank?) → target, behavior: toggle |
momentary}` living app-side in `lib/control/`, momentary capture/restore
semantics with a single release-all enforcement point in `ControlCubit`, an
assignment screen composing Part 6a's extracted `PedalFaceplate` widget, and
stomp/LED state chips on chain cards. Persistence rides `Session` as an
opaque blob with a wholesale session-over-global merge rule.

## Dependencies

Must be merged first (this part stacks on them):

- `2026-07-28-feat-fx-system-v3-part-6a-plan.md` — presentational
  `PedalFaceplate` widget (injected `PedalStateFrame`, `onPress`, per-button
  selection state) that the assignment screen composes [R22]
- `2026-07-28-feat-fx-system-v3-part-5b-plan.md` — `InteractionMode.fx`,
  FX-mode contextual button matrix, `ControlCubit` FX-mode branches that
  remaps override
- `2026-07-28-feat-fx-system-v3-part-3a-plan.md` — `FxAddress` + canonical
  JSON serialization + stable per-slot `slotId`s [A9][R19], per-effect /
  per-chain `enabled` domain APIs the targets resolve against

## Context

Key files:

- `lib/control/cubit/control_cubit.dart` — the ONE control-surface
  interpreter; button dispatch switch sites at `control_cubit.dart:575-599`
  plus `_onPress`; FX-mode branches landed in Part 5b. Remap resolution and
  the momentary release-all enforcement point live here.
- `lib/control/` — home of the binding model and the typed sealed target +
  resolution (app-side, next to `ControlCubit`) per the epic's ownership
  decision [VGV].
- `packages/session_repository` — `Session` gains the per-session binding
  set as an **opaque blob** (the `SessionLaneChain.encoded` chains pattern);
  **never `SessionRig`** [VGV].
- `lib/session/session_mapping.dart` — session capture/apply seams where the
  blob is written/read app-side.
- `_PluginPlaceholderCard` (Signal page FX cards) — the established
  missing-target visual convention (tertiary text + warning glyph, entry
  preserved) that stale bindings reuse [R25].
- Part 4's chain cards / dock headers on the Signal page — where the
  stomp/LED state chips attach.

Constraints lifted from the index (pinned decisions — do not change):

- **Type ownership + dependency arrows [VGV-critical]:** binding targets
  cross the `pedal_repository` / `controller_repository` boundary as
  **canonical-JSON strings** — those packages gain **no looper/engine
  dependency**. The typed sealed target + resolution live app-side in
  `lib/control/`. `ControlCubit` is the single dispatch point for
  toggle/momentary interpretation; no second control-surface interpreter
  grows in a repository package. Canonical `FxAddress` JSON is declared in
  Part 3a and referenced here, never redeclared [R19].
- Target = chain (`FxAddress`) or effect (`FxAddress` + `slotId`) [A9];
  effect-level bindings go **inert (never retarget)** when the slotId is
  gone.
- Track buttons bind **per-bank**; all other buttons per-button [A3].
- **MODE and Bank are never remappable** [B12]; remaps override contextual
  defaults but never long-press system gestures (MODE long-press stays
  performance-record arm; Stop long-press stays FX-panic restore).
- Merge rule [A12]: a session with **any** bindings overrides the global set
  **wholesale**; otherwise globals apply. No per-button merging.

## Tasks

- [ ] **Binding model in `lib/control/`** [VGV]: pure-data
      `{(button, bank?) → target, behavior: toggle | momentary}`; targets
      stored as canonical-JSON strings (Part 3a's `FxAddress` form, plus
      `slotId` for effect-level targets) [A9][R19]; track buttons keyed
      per-bank, others per-button [A3]; model-level rejection of MODE and
      Bank as bindable buttons [B12]; JSON round-trip for the whole set
      (this is the session blob payload)
- [ ] **Typed sealed target + resolution** app-side next to `ControlCubit`:
      decode canonical-JSON string → sealed target; resolve chain targets to
      per-chain `enabled`, effect targets to per-slot `enabled` via the
      Part 3a domain APIs; unresolvable target (missing chain or slotId) →
      inert, never retargets [A9]
- [ ] **Remap dispatch in `ControlCubit`**: in FX mode, a bound button
      overrides its contextual default; unbound buttons keep Part 5b
      behavior; long-press system gestures and MODE/Bank handling are
      untouched by any binding [B12]
- [ ] **Momentary semantics** [B1]: press captures the target's prior
      enabled state and enables; release restores the captured state;
      last-writer-wins across overlapping writers (UI toggles, other
      bindings) — documented in the model's doc comment
- [ ] **Release-all rule at ONE `ControlCubit` enforcement point** [B1]: all
      held momentaries restore their captured state on (a) mode exit,
      (b) binding-set change — including live edits from the assignment
      screen, (c) session load, (d) pedal disconnect
- [ ] **Stale-target behavior** [R25][flow err-2]: mid-song stomp on a stale
      binding = no-op + unlit LED; assignment screen renders broken bindings
      in the `_PluginPlaceholderCard` convention (tertiary text + warning
      glyph, entry preserved) with **rebind** and **clear** actions
- [ ] **Persistence + merge** [A12]: global binding set in settings; the
      per-session set rides `Session` in `session_repository` as an opaque
      blob (chains pattern, never `SessionRig`) [VGV]; wholesale
      session-over-global merge; session save→load round-trip preserves
      bindings byte-identically
- [ ] **Assignment screen**: composes the Part 6a `PedalFaceplate` widget
      (tap a footswitch → select it; selection state via the widget's
      injected per-button selection API); per-button/per-bank binding rows
      with target picker (chains + effects with stable slotIds) and
      toggle/momentary behavior choice; rebind/clear on every row; MODE and
      Bank not offered [B12]
- [ ] **Stomp/LED state chips** on chain cards/headers (Signal page):
      pedal-bound indicator + current state; land here, not Part 4 — they
      depend on the binding model [R25]; dim/strike behavior follows
      Part 4's `SurfaceTheme` token conventions (no ad-hoc opacity
      constants) [VGV]
- [ ] **l10n + semantics** [R24]: assignment screen strings in both ARBs;
      Semantics on binding rows, target picker, behavior choice, and the
      chips
- [ ] **Tests**:
      - `bloc_test`s: bind → stomp → correct toggle; momentary
        capture/restore incl. last-writer-wins; remap-overrides-contextual;
        MODE/Bank unbindable
      - **No stuck momentary** across pedal disconnect, mode switch, and
        session load [B1][flow SC-2]
      - **Binding stability under slot insert/reorder** (slotId targets
        survive; positional churn never retargets) [A9][flow SC-4]
      - Stale-binding UI round-trip: delete bound effect → placeholder row →
        rebind and clear paths [R25]
      - Wholesale merge: session-with-bindings overrides globals entirely;
        session-without falls back to globals [A12]; blob round-trip in
        `session_repository`
      - Widget tests for the assignment screen + chips

## Success Criteria

```success-criteria
GOAL: Optional per-session pedal remap with safe momentary semantics and a discoverable assignment surface — bind → stomp → correct toggle, and no binding can ever wedge or destroy state.

SUCCESS CRITERIA:
- Binding model + dispatch: bound button overrides contextual default; MODE/Bank never remappable; long-press gestures untouched [B12] | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal test/control
- No stuck momentary across disconnect / mode-switch / session-load, enforced at one ControlCubit point [B1][flow SC-2] | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal test/control
- Binding stability under slot insert/reorder — slotId targets never retarget, stale targets go inert [A9][flow SC-4] | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal test/control
- Stale-binding UI round-trip: placeholder convention + rebind/clear actions [R25] | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal test/control
- Persistence: wholesale session-over-global merge + opaque-blob session round-trip [A12] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/session_repository test/control
- Assignment screen composes the 6a faceplate widget; stomp/LED chips on chain cards; l10n + semantics [R24][R25] | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal test/control

NON-GOALS:
- Faceplate extraction itself — Part 6a owns the PedalFaceplate widget and its goldens
- FX-mode entry, contextual button matrix, wire protocol v3 / firmware — Parts 5a/5b
- FxAddress, slotIds, canonical JSON declaration, enabled domain APIs — Part 3a
- Expression / MIDI-CC bindings and the discrete-CC dispatch path — Part 7 (it reuses this part's sealed target type and release-all rule)
- Engine bypass mechanics — Part 1
- Stage-overview UI beyond the stomp/LED chips — Part 4

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test test/pedal test/control
```

## Notes

- **No native surface in this part** — no ffigen regen needed. If rebasing
  over engine parts that did touch native APIs, remember the repo gotcha:
  ffigen emits short-style and churns whole files; run `dart format` after
  any regen.
- **Before opening the PR**: check the cspell dictionary (stomp/remap/
  momentary vocabulary) and the semantic PR title, not after CI fails.
- **Stacked-PR squash landmines**: this part stacks on 6a + 5b + 3a. Squash
  merges break child merge-refs (CI silently absent) and API branch-deletes
  close children; rebase this branch onto its own parent's baseline after
  each parent lands, per repo discipline.
- **Goldens are author-machine-only**: any assignment-screen goldens and the
  chain-card chip changes need regen + eyeball on the author machine;
  elsewhere they skip silently.
- **testWidgets stream-cancel hang**: `await sub.cancel()` inline in a
  `testWidgets` body hangs forever (flutter/flutter#139870) — use
  `unawaited()` or `tearDown()`; relevant for pedal-connection stream tests
  around the disconnect release-all cases.
- Package CI jobs for `session_repository` / `pedal_repository` were added
  with the first Dart part (Part 3a's CI-gate fix) — keep their
  `min_coverage` green; this part adds tests in both.
