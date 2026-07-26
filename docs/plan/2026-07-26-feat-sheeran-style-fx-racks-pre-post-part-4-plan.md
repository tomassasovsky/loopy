---
title: feat: Sheeran-style FX racks — part 4 (factory + user presets)
type: feat
date: 2026-07-26
issue: 351
part: 4
---

## feat: Sheeran-style FX racks — part 4 (factory + user presets) - Standard

> Epic index: [2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md](2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md)
> Issue: [#351](https://github.com/tomassasovsky/loopy/issues/351)
> Branch: `feat/sheeran-style-fx-racks`

## Dependencies

**Requires part 3 merged** (FX page to host apply/save/load UX).

## Overview

Add a **full factory rack preset library** (Sheeran-class categories, Loopy
built-ins only) plus **user save/load/rename/delete**. Presets describe effect
graphs and a suggested Pre/Post placement; users can override after apply.

## Problem Statement / Motivation

Pre/Post + FX page work, but performers still build every chain from scratch.
Sheeran ships purpose-built racks; Loopy needs the same product completeness
without proprietary Sheeran assets.

## Proposed Solution

### Format

- Versioned JSON (or equivalent) listing ordered built-in effect types + params
- Optional `suggestedStage`: `pre` | `post` (default apply target)
- Factory packs under `assets/fx_racks/` (or a small package data dir)
- **No** Sheeran binary/IR rip

### Categories (minimum set)

Vocal, Guitar, Dub, Lo-Fi, Drum, Studio, Rhythmic (and peers as content allows),
each with ≥1 usable pack built from Loopy Delay/Reverb/Drive/Filter/etc.

### Persistence (P10)

- Factory: app assets
- User presets: `local_storage_client` / settings or app-support path; appliance
  mirror under `/data` documented in `docs/RUNNING_ON_RPI.md`
- Do **not** stuff user presets into `session_repository` unless session-scoped
  snapshot is explicitly needed (default: global user library)

### UX

- Browse/apply from FX page (input or track target)
- Save current Pre or Post chain (or both — pick one UX: save **active chain**
  first; “save both as rack” if trivial)
- Load replaces the target chain (confirm if non-empty)

### Layering

- Parse/apply in a small domain/helper (not in widgets)
- Bloc events: `FxPresetApplied`, `FxPresetSaved`, …

### Tasks

- [ ] Preset schema + loader
- [ ] Author factory library content
- [ ] User preset store + appliance path note
- [ ] FX page browse/apply/save/load UI + l10n
- [ ] Roundtrip tests (apply → save → load)

## Technical Considerations

- **Architecture:** Keep preset types out of `session_repository`.
- **Performance:** Lazy-load factory JSON.
- **Security:** Validate preset JSON (type enums, param ranges, max chain length).

## Success Criteria

```success-criteria
GOAL: Factory racks can be browsed and applied; user presets round-trip effect types and params across restart.

SUCCESS CRITERIA:
- Factory packs load and apply onto Input/Track Pre or Post without crash | verify: /Users/Tomas/development/flutter/bin/flutter test --name "FxRack preset|factory rack|FxPreset"
- User preset save/load round-trips types + params | verify: /Users/Tomas/development/flutter/bin/flutter test --name "FxRack preset|user preset|FxPreset"
- Factory categories include at least Vocal, Guitar, Dub (or documented rename) | verify: rg -n "Vocal|Guitar|Dub" assets/fx_racks packages -g '*.json' | head
- l10n for preset UI in both ARBs | verify: rg -n "preset|Preset|fxRack" lib/l10n/arb/app_en.arb lib/l10n/arb/app_es.arb
- Analyzer clean on preset + FX page touch points | verify: /Users/Tomas/development/flutter/bin/flutter analyze lib/looper/view/fx_page

NON-GOALS:
- Pedal/expression assign
- Bounce As Loop
- VST3-only factory packs (#194)
- Proprietary Sheeran assets

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test --name "FxRack preset|FxPreset|factory rack|user preset"
```

## Success Metrics

- ≥1 factory pack per required category
- User preset survives app restart

## Dependencies & Risks

- Part 3 FX page
- Content authorship time — do not block parts 1–3
- Plugin slots in presets: built-ins only until #194 coordination

## References & Research

- Epic Presets section
- Sheeran FX rack categories (reference only — rebuild with Loopy DSP)
- `packages/settings_repository` / `local_storage_client` patterns
