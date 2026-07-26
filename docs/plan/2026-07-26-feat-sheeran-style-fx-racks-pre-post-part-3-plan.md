---
title: feat: Sheeran-style FX racks — part 3 (dedicated FX page)
type: feat
date: 2026-07-26
issue: 351
part: 3
---

## feat: Sheeran-style FX racks — part 3 (dedicated FX page) - Standard

> Epic index: [2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md](2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md)
> Issue: [#351](https://github.com/tomassasovsky/loopy/issues/351)
> Branch: `feat/sheeran-style-fx-racks`

## Dependencies

**Requires part 2 merged** (domain Pre/Post + Live Signal + session migration).

## Overview

Ship a dedicated **FX page** (Sheeran-like structure, Loopy design system): Input
column | Track column, chain slots with Pre/Post, Live Signal control, edit
drill-in. Signal page remains routing/levels; it stops being the primary FX
editor.

## Problem Statement / Motivation

Domain APIs exist but performers still configure FX through Signal docks with
legacy “prints into new takes” / “shapes playback” copy. Happy path
(Pre delay + Post reverb + Live Signal) needs a clear product surface.

## Proposed Solution

### Navigation (lock in PR description before UI land)

- **Primary:** Control Center / settings host entry labeled FX (or equivalent)
- **Secondary:** Signal row affordance → push FX page (demote inline dock editing)
- Wire through `lib/app/loopy_navigator.dart` (or Control Center host router)

### Layout

- Input column: select input → show Pre chain + Post chain (or unified slot list
  with Pre/Post toggle that moves effects between lists)
- Track column: same + **Live Signal** Auto/Off/On
- Drill-in: reuse widgets from `lib/looper/view/fx_editor/` /
  `signal_fx_rack.dart` via evolved `FxScope` (or `InputPreFxScope` /
  `TrackPostFxScope` successors)

### Layering (hard rule)

- Widgets → **Bloc/Cubit events** (`LooperBloc` / `MonitorCubit` or dedicated
  `FxRacksCubit`) → repository. **No** direct `LooperRepository` FX calls from
  widgets.
- Push `setLiveSignalFocus` when the user selects a track on the FX page (and
  from the main looper selection if that is the product choice — document).

### Copy / l10n

- Both `lib/l10n/arb/app_en.arb` and `app_es.arb`
- No string literals in new views
- Retire/replace `fxEditorInputConsequence` / lane “prints into new takes”
  language with Pre/Post explanations

### Tasks

- [ ] Lock nav entry (primary + secondary)
- [ ] FX page shell + selection model
- [ ] Pre/Post chain editing + Live Signal control
- [ ] Evolve `fx_scope.dart` / scopes for Pre vs Post
- [ ] Bloc/Cubit wiring + focus push
- [ ] Demote Signal FX dock as primary editor (deep-link to FX page or read-only
      summary — choose one; prefer navigate-to-FX-page)
- [ ] Widget tests under `test/looper/view/fx_page/`
- [ ] Update existing `fx_editor` / `signal_fx_*` tests for new copy/scopes

## Technical Considerations

- **Architecture:** Presentation → Bloc → repository → engine (VGV layering).
- **Performance:** UI-only; avoid rebuilding entire page on every param tick
  (follow existing dock patterns).
- **A11y:** Pre vs Post must be exposed in semantics, not color alone.

## Success Criteria

```success-criteria
GOAL: Performers can configure Input/Track Pre+Post and Live Signal on a dedicated FX page through Bloc scopes, enabling the happy-path song setup in UI tests.

SUCCESS CRITERIA:
- FX page widget tests cover Pre delay + Post reverb + Live Signal assignment | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/fx_page/
- No new user-facing string literals outside ARBs in FX page / new scopes | verify: rg -n "['\"]prints into|shapes playback" lib/looper/view/fx_page lib/looper/view/fx_editor && test $? -eq 1 || true
- l10n keys exist in both app_en.arb and app_es.arb for Pre/Post/Live Signal | verify: rg -n "liveSignal|fxPre|fxPost|LiveSignal" lib/l10n/arb/app_en.arb lib/l10n/arb/app_es.arb
- Widgets do not call LooperRepository FX setters directly | verify: rg -n "LooperRepository" lib/looper/view/fx_page && ! rg -n "set(Input|Track|Monitor|Lane).*Effect|setTrackLiveSignal" lib/looper/view/fx_page
- Analyzer clean on FX UI | verify: /Users/Tomas/development/flutter/bin/flutter analyze lib/looper/view/fx_page lib/looper/view/fx_editor

NON-GOALS:
- Factory preset browser (part 4)
- Export/undo hardening (part 5)
- Pixel-perfect Sheeran clone

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/fx_page/ && /Users/Tomas/development/flutter/bin/flutter analyze lib/looper/view/fx_page lib/looper/view/fx_editor
```

## Success Metrics

- Happy path configurable without Signal dock as primary editor
- Manual listen criteria remain on epic (part 5 / release) — UI tests prove
  configuration wiring

## Dependencies & Risks

- Part 2 domain APIs
- Risk: dual editors confuse users — demote Signal FX aggressively
- Risk: Live Signal focus fights main track selection — document single source

## References & Research

- `lib/looper/view/fx_editor/fx_scope.dart`, `fx_dock.dart`
- `lib/looper/view/signal_graph/signal_fx_rack.dart`
- `docs/plan/2026-07-03-feat-fx-screen-redesign-plan.md`
- Epic happy path narrative
