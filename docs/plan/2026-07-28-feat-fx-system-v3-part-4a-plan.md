---
title: "chore(ui): delete dead FX editor code + orphaned l10n"
type: chore
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

## Overview

Pure dead-code removal lifted from FX system v3 Part 4: delete the superseded
FX editor widgets (`fx_inspector`, `fx_chain_strip`, `fx_param_control`,
`effect_params_editor`), the dead `routing_graph` effect widgets, their tests,
and the l10n keys that become orphaned — in both ARBs. Per the epic's memory
note, these files are confirmed dead code from the shipped FX screen redesign
(dock pivot #119). No behavior change; nothing imports any of them today
(verified by grep — zero live importers or barrel references in `lib/`).

## Dependencies

None — can land anytime, independently of every other part
(`-part-1` … `-part-9` files). It unblocks nothing and is blocked by nothing.

## Context

Lifted from the index's Part 4 bullet: "Delete dead FX code:
`fx_inspector.dart`, `fx_chain_strip.dart`, `fx_param_control.dart`,
`effect_params_editor.dart`, dead `routing_graph` effect widgets (+ tests,
orphaned l10n keys; keep `fxBlockName`)."

**Files to delete (all verified to have zero live importers):**

- `lib/looper/view/fx_editor/fx_inspector.dart` + `test/looper/view/fx_editor/fx_inspector_test.dart`
- `lib/looper/view/fx_editor/fx_chain_strip.dart` + `test/looper/view/fx_editor/fx_chain_strip_test.dart`
- `lib/looper/view/fx_editor/fx_param_control.dart` + `test/looper/view/fx_editor/fx_param_control_test.dart`
- `lib/common/effect_params_editor.dart` + `test/common/effect_params_editor_test.dart`
- `packages/routing_graph/lib/src/widgets/add_effect_button.dart` + `packages/routing_graph/test/src/widgets/add_effect_button_test.dart`
- `packages/routing_graph/lib/src/widgets/effect_chain_card.dart` + `packages/routing_graph/test/src/widgets/effect_chain_card_test.dart`
- `packages/routing_graph/lib/src/widgets/effect_drop_zone.dart` + `packages/routing_graph/test/src/widgets/effect_drop_zone_test.dart`

**Barrel fallout:** `packages/routing_graph/lib/routing_graph.dart` exports the
three dead widgets (lines 15, 17, 18) and names them in its library doc comment
(lines 4–5) — prune both.

**l10n keys orphaned by this deletion** (remove from BOTH
`lib/l10n/arb/app_en.arb` and `lib/l10n/arb/app_es.arb`):

- `fxEditorChainIn` / `fxEditorChainOut` — only user is `fx_chain_strip.dart` (en:587-588, es:304-305)
- `fxEditorEmptySelection` — already zero users today (en:589, es:306)
- `octaverLatencyHint` — only user is `effect_params_editor.dart`

**Keys that stay (verified live users):** `fxEditorScopeGone` (`fx_dock.dart:80`),
`fxEditorEditBlock` (`fx_block_chip.dart:64`), `fxEditorInputTitle` /
`fxEditorInputConsequence` / `fxEditorLaneConsequence` (`fx_scope.dart:100-182`),
and everything else the dead files share with live code (`effectTypeLabel`,
`removeEffectTooltip`, `effectParamLabel`, `octaverModeLabel`,
`formatLocalizedPitchShift`, `signalAddEffect`, `signalAddPlugin`, `emDash`,
`signalPlugin*`).

**`fxBlockName`:** it is a Dart helper, not an ARB key — defined at
`lib/looper/view/fx_editor/fx_block_chip.dart:9` and used live by
`signal_fx_summary.dart:52` and `fx_block_chip.dart:58`. `fx_block_chip.dart`
stays, so **no extraction is needed** — just keep the file untouched.

**Constraint lifted from the index:** this part does NOT touch
`signalPluginBypassTooltip` — its retire/repurpose is D-POWER fallout owned by
Part 4 proper [R23].

## Tasks

- [ ] Delete the seven dead widget files and their seven test files listed in
      Context (`git rm`).
- [ ] Prune `packages/routing_graph/lib/routing_graph.dart`: drop the three
      export lines (15, 17, 18) and the doc-comment mentions of
      `EffectChainCard`s / `EffectDropZone`s / `AddEffectButton` (lines 4–5).
- [ ] Remove the orphaned keys (`fxEditorChainIn`, `fxEditorChainOut`,
      `fxEditorEmptySelection`, `octaverLatencyHint`) and their `@`-metadata
      entries from BOTH `app_en.arb` and `app_es.arb`; leave every key with a
      live user untouched.
- [ ] Run the app suite + `routing_graph` package suite; confirm the analyzer
      is clean (regenerated localizations no longer expose the removed
      getters).
- [ ] Open the PR: `Closes` the child issue, labels `stage:in-review` +
      `autonomy:auto` + `ci:*` + `review:pending` per `docs/TRACKING.md`
      (reversible, narrow, fully verifiable here).

## Success Criteria

```success-criteria
GOAL: The dead FX editor surface and its orphaned l10n keys are gone, with zero behavior change and green suites.

SUCCESS CRITERIA:
- Dead files deleted; app looper suite green (scope-directive verify) | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper && ! ls lib/looper/view/fx_editor/fx_inspector.dart 2>/dev/null
- No reference to any deleted symbol survives anywhere | verify: ! grep -rn "FxInspector\|FxChainStrip\|FxParamControl\|EffectParamsEditor\|AddEffectButton\|EffectChainCard\|EffectDropZone" lib test packages/routing_graph/lib packages/routing_graph/test
- Orphaned keys gone from both ARBs | verify: ! grep -n "fxEditorChainIn\|fxEditorChainOut\|fxEditorEmptySelection\|octaverLatencyHint" lib/l10n/arb/app_en.arb lib/l10n/arb/app_es.arb
- fxBlockName helper kept in place, untouched | verify: grep -q "String fxBlockName" lib/looper/view/fx_editor/fx_block_chip.dart
- routing_graph package suite green after widget + export removal | verify: /Users/Tomas/development/flutter/bin/flutter test packages/routing_graph

NON-GOALS:
- The four-stage Signal surface, StageFxScope, D-POWER single power control, and the signalPluginBypassTooltip retire/repurpose — owned by Part 4 proper
- Any engine/native change (Parts 1–2), domain/session model change (Part 3), pedal work (Parts 5–6), or expression work (Part 7)
- Removing any l10n key that still has a live user; touching fx_dock.dart, fx_scope.dart, or fx_block_chip.dart

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test test/looper && ! ls lib/looper/view/fx_editor/fx_inspector.dart 2>/dev/null
```

## Notes

- **Test runner gotcha:** the very_good MCP test wrapper is broken in this
  repo — use the absolute Flutter path
  (`/Users/Tomas/development/flutter/bin/flutter`) for every invocation.
- **No native surface touched** — the ffigen-regen + `dart format` gotcha does
  not apply to this part.
- **l10n regen:** localizations regenerate from `l10n.yaml` on the next
  build/test; if the analyzer still sees the removed getters, run
  `/Users/Tomas/development/flutter/bin/flutter gen-l10n` once.
- **Coverage:** the root CI job enforces `min_coverage 90`; deleting code and
  its tests together should be coverage-neutral or better, but check the CI
  coverage step if it dips.
- **Before opening the PR:** semantic PR title (`chore(ui): …` passes) + cspell
  dictionary check — deletions can leave now-unused dictionary words, which is
  fine, but the title and any new prose must pass.
- **Stacked-PR squash landmines:** this part is standalone (no parent branch),
  so the usual child-merge-ref hazards don't apply — still branch from
  `master`, never from another part's branch.
- **Screenshot goldens are author-machine-only:** no rendered UI changes here,
  so no golden churn is expected; if `test/screenshots` fails on the author
  machine, that signals an accidental live-code edit — stop and re-check the
  diff rather than regenerating.
