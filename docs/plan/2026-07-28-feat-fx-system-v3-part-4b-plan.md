---
title: "feat(ui): four-stage Signal surface, single power control, inherited badges"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

## Overview

Turn the existing Signal page into the four-stage FX surface: Track chains get
an FX summary row on each track group header, Master gets a strip row in the
outputs pane, and the Loop stage drills in grouped by track — no new page, no
new tray tile [R21]. Every effect card gets one universal power control
(replacing the plugin `_BypassToggle`) plus a chain-level enable in the dock
header [R23], disabled state renders via `SurfaceTheme` tokens [R26], and loop
chains surface their inheritance provenance (badge, re-sync action, overdub
mismatch hint) [A6][A7].

## Dependencies

Must be merged before this part builds:

- `docs/plan/2026-07-28-feat-fx-system-v3-part-3a-plan.md` — domain model this
  UI binds to: `FxAddress {stage, index, lane?}` + stable slotIds [A9],
  `TrackEffect.enabled`, the chain envelope `{chainEnabled, meta, entries}`
  with `inheritedFrom` provenance meta [A6][R13], four-stage chain APIs +
  enabled setters on `looper_repository`, `LooperBloc` owning Track and Master
  chain state (events + push) [VGV], and the domain-exposed "input chain ≠
  loop chain during overdub" signal [A7].
- `docs/plan/2026-07-28-feat-fx-system-v3-part-4a-plan.md` — the first Part 4
  UI slice (including the dead-FX-code deletion index bullet:
  `fx_inspector.dart`, `fx_chain_strip.dart`, `fx_param_control.dart`,
  `effect_params_editor.dart`, dead `routing_graph` effect widgets). This part
  builds on the Signal-page/dock state 4a leaves behind and does not re-do any
  of it.

## Context

Key files (all paths repo-relative):

- `lib/looper/view/signal_graph/signal_panes.dart` — the Signal page panes:
  `_InputsPane` (:156), `_TracksPane` (:262), `_OutputsPane` (:416). This part
  adds the Track FX summary row to track group headers in `_TracksPane` and the
  Master strip row to `_OutputsPane`.
- `lib/looper/view/signal_graph/signal_fx_summary.dart` — `SignalFxSummary`
  (:13), `_SummaryChip` (:66), `_AddFxChip` (:91): the summary-row + empty
  affordance building blocks to reuse for the new stage rows.
- `lib/looper/view/signal_graph/signal_fx_rack.dart` — effect cards.
  `_BypassToggle` (:937), the plugin `_bypassParam` getter (:562), and the
  `Key('${keyPrefix}_bypass')` test key (:715) are the D-POWER removal targets
  [R23]. The plugin placeholder card pattern (missing/loading/unsupported)
  lives here — the established missing-target convention for [err-1].
- `lib/looper/view/fx_editor/fx_scope.dart` — `FxScope` (:17) with the "no
  mix, no bypass" doc comment (:16) that must update; `InputFxScope` (:78),
  `LaneFxScope` (:157). The new stage-parameterized `StageFxScope` lands
  beside them.
- `lib/looper/view/fx_editor/fx_dock.dart` — `FxDock` (:21), `_FxDockHeader`
  (:124): single editing surface for all four stages; chain-level enable and
  per-stage consequence lines land in the header.
- `lib/theme/surface_theme.dart` — `SurfaceTheme` `ThemeExtension` (:11): the
  only source of disabled-state dimming tokens [R26][VGV] (no ad-hoc opacity
  constants, no pixel params in widget APIs).
- `lib/l10n/arb/app_en.arb` (`signalPluginBypassTooltip` :554) and
  `lib/l10n/arb/app_es.arb` (:271) — both ARBs change together, always.
- `test/looper/` — widget/bloc tests; `test/screenshots/` — author-only
  screenshot goldens (skip everywhere but the author's machine).

Constraints lifted from the index (pinned — do not revisit):

- **D-OVERVIEW [R21]: no new page.** The Signal page's existing panes *are*
  the stage layout. Input chains stay on input cards. All editing stays in the
  single `FxDock`. Console path: tray → Signal (no new tray tile).
- **One stage-parameterized `StageFxScope`** for the two new stages — stage is
  data in `FxAddress`, not a type; fold the existing input/lane scopes in only
  if trivially cheap [simplicity].
- **D-POWER [R23]: one power control per card.** The universal per-slot enable
  replaces `_BypassToggle`; the plugin's own bypass param is hidden from the
  header (still reachable in the plugin's native editor; it is part of the
  plugin's sound and never drives host enable).
- **Inheritance is by-value copy with provenance** [A6][R13]: the badge reads
  the envelope's `inheritedFrom` meta; divergence (any edit = detach) clears
  the marker only — nothing ever propagates to existing takes. **Overdub never
  re-inherits** [A7].
- Loop drill-in: only tracks with recorded loops; non-empty lanes by default,
  "all lanes" expander [A11].
- **Stomp/LED state chips on chain cards/headers are NOT this part** — they
  depend on the binding model and land in part 6 [R25]. The cache debug glyph
  is part 9 [R27].

## Tasks

- [ ] **Stage overview surface (D-OVERVIEW [R21])**
  - [ ] Track FX summary row on each track group header in `_TracksPane`
        (`signal_panes.dart:262`), built from `SignalFxSummary`; tap opens
        `FxDock` on that track's Track-stage chain.
  - [ ] Master strip row in `_OutputsPane` (`signal_panes.dart:416`); tap
        opens `FxDock` on the Master chain.
  - [ ] Loop-stage drill-in grouped by track: only tracks with recorded loops
        appear; non-empty lanes shown by default with an "all lanes" expander
        [A11]. Input cards unchanged.
  - [ ] Console path verified: settings tray → Signal reaches every stage; no
        new tray tile.
- [ ] **`StageFxScope` [simplicity]**: one stage-parameterized `FxScope`
      subclass in `fx_scope.dart` covering Track and Master (stage carried as
      data in `FxAddress`, not a type); reuse `LooperBloc`'s track/master
      chain events from part 3a; fold `InputFxScope`/`LaneFxScope` into it
      only if trivially cheap — otherwise leave them.
- [ ] **D-POWER single power control [R23]**
  - [ ] Per-card enable toggle on every effect card (built-ins and plugins
        uniformly), wired to the part-3a `setEffectEnabled` path.
  - [ ] Remove `_BypassToggle` (`signal_fx_rack.dart:937`); hide the plugin
        bypass param from the header (`_bypassParam`,
        `signal_fx_rack.dart:562`) — still reachable in the plugin's native
        editor, never drives host enable.
  - [ ] Tasked fallout: `Key('${keyPrefix}_bypass')`
        (`signal_fx_rack.dart:715`) + its tests migrate to the enable-toggle
        key; `signalPluginBypassTooltip` retired or repurposed in BOTH ARBs
        (`app_en.arb:554`, `app_es.arb:271`); `FxScope` gains
        `setEffectEnabled` / `setChainEnabled` across all four scopes; the
        "no mix, no bypass" doc comment (`fx_scope.dart:16`) updates.
- [ ] **Chain-level enable in the dock header** (`_FxDockHeader`,
      `fx_dock.dart:124`) for all four stages; plain-language consequence
      line per stage (what disabling this chain does to what you hear).
- [ ] **Disabled-state rendering [R26]**
  - [ ] Disabled cards dim via `SurfaceTheme` tokens
        (`lib/theme/surface_theme.dart:11`) — no ad-hoc opacity constants
        [VGV]; card headers stay interactive while dimmed.
  - [ ] Placeholder cards (D-MISS / loading) keep their warning state
        visually dominant over the disabled dim.
  - [ ] Summary chips (`_SummaryChip`) dim per-effect; the whole row
        strikes/dims when the chain is disabled.
  - [ ] Track and Master stages get the same add-FX empty affordance as
        input/lane cards (`_AddFxChip`, `signal_fx_summary.dart:91`).
- [ ] **Inheritance surface [A6][A7]**
  - [ ] Inherited badge on loop chains, read from the envelope
        `inheritedFrom` meta; badge clears on divergence (detach clears the
        marker only — never touches audio or other takes).
  - [ ] "Re-sync from input" action on a loop chain: by-value re-copy of the
        routed input chain (fresh provenance stamp), explicit and user
        initiated — never automatic.
  - [ ] Overdub mismatch hint: while overdubbing with input chain ≠ loop
        chain (domain signal from part 3a), show the plain-language hint that
        the overdub is captured dry and does not re-inherit [A7].
- [ ] **Plugin placeholder badges in overview [err-1]**: plugin
      unavailable/loading/unsupported states surface on the stage overview
      summary rows (same convention as the placeholder cards in
      `signal_fx_rack.dart`), not just inside the dock.
- [ ] **l10n**: every new string in BOTH ARBs (`app_en.arb` + `app_es.arb`) —
      stage row labels, enable/disable tooltips, consequence lines, inherited
      badge + re-sync action, overdub hint, placeholder badge text.
- [ ] **A11y**: Semantics on every enable toggle (effect + chain, state
      announced), on the inherited badge, and on the new summary rows.
- [ ] **Widget tests** (`test/looper/`): stage rows appear/route to the dock;
      enable toggle flips state per-slot and per-chain through the scope;
      plugin card shows exactly one power control; disabled dim + interactive
      header; inherited badge shows → clears on edit → re-sync restores;
      overdub hint appears only during mismatch; placeholder badge in
      overview; key migration (`_bypass` key gone).
- [ ] **Screenshot goldens**: regen + eyeball (author-only runner) for the
      Signal page and dock after the redesign.

## Success Criteria

```success-criteria
GOAL: The Signal page is the complete four-stage FX surface — Track/Master rows, one power control everywhere, honest disabled rendering, and visible inheritance provenance — with no new page.

SUCCESS CRITERIA:
- Track FX summary rows on track group headers + Master strip row in outputs pane + loop drill-in grouped by track with all-lanes expander, all opening the single FxDock [R21][A11] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper
- One stage-parameterized StageFxScope drives Track and Master editing in the dock; stage is data, not a type [simplicity] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper
- Single power control per card: _BypassToggle gone, ${keyPrefix}_bypass key migrated, plugin bypass param hidden from header, FxScope has setEffectEnabled/setChainEnabled on all four scopes [R23] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper && ! grep -rn "_BypassToggle" lib
- Chain-level enable + per-stage consequence line in the dock header; disabled cards/chips dim via SurfaceTheme tokens with interactive headers and warning-dominant placeholders [R26][VGV] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper
- Inherited badge shows from provenance meta, clears on divergence, re-sync action re-copies by value, overdub mismatch hint appears during overdub only [A6][A7] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper
- Plugin unavailable/loading/unsupported badges visible in the stage overview [err-1] | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper
- Every new string in both ARBs; Semantics on all toggles and badges | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper

NON-GOALS:
- Dead FX code deletion (fx_inspector.dart, fx_chain_strip.dart, fx_param_control.dart, effect_params_editor.dart, routing_graph effect widgets) — part 4a owns it
- Domain model, chain envelope, slotIds, session migration, arm fix — part 3a (and its siblings)
- Engine enabled flags, ramps, track bus, wet cache — parts 1 and 2
- Stomp/LED state chips on chain cards/headers — part 6 [R25]
- Cache debug glyph on lane cards — part 9 [R27]
- Pedal FX mode, protocol v3, expression mapping — parts 5–7
- Any new page or new console tray tile (D-OVERVIEW forbids both) [R21]

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test test/looper
```

## Notes

- **No native surface in this part** — pure Dart/UI on top of part 3a's
  domain APIs, so no ffigen regen. (If a rebase pulls in native churn from
  parts 1/2, remember the repo gotcha: ffigen regen must be followed by
  `dart format` or the whole file churns.)
- **Before opening the PR**: check the cspell dictionary for any new vocabulary
  and the semantic PR title (`feat(ui): ...`) — both are CI gates that are
  cheaper to satisfy up front than after a red run.
- **Stacked-PR squash landmines**: this part stacks on 3a + 4a. Squash-merging
  a parent breaks child merge-refs (CI silently absent on the child) and an
  API branch-delete closes children — rebase this branch onto the landed
  parent immediately after each parent merges, and diff against the child's
  own parent baseline, not master.
- **Goldens are author-machine-only**: `test/screenshots/` skips everywhere
  but the author's machine (fonts), so goldens rot silently — regen and
  eyeball them as part of this UI redesign, not as an afterthought. CI green
  does not prove the goldens are current.
- **PR hygiene per the tracking contract**: child issue labeled with its
  `stage:*` + `autonomy:*`, PR body carries `Closes #<child>` plus gate labels
  (`ci:*`, `review:pending`); mergeable only when CI is green and
  `/code-review` is clean.
