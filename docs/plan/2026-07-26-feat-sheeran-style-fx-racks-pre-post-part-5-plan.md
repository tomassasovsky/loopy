---
title: feat: Sheeran-style FX racks — part 5 (hardening + export)
type: feat
date: 2026-07-26
issue: 351
part: 5
---

## feat: Sheeran-style FX racks — part 5 (hardening + export) - Standard

> Epic index: [2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md](2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md)
> Issue: [#351](https://github.com/tomassasovsky/loopy/issues/351)
> Branch: `feat/sheeran-style-fx-racks`

## Dependencies

**Requires parts 1–3 merged** (engine + domain + FX page).  
Part 4 (presets) is nice-to-have but **not** required for export/undo work.

## Overview

Harden Pre/Post contracts (clear/undo, mid-record edits, multi Live Signal On),
update **DAW/performance export** so Pre-baked PCM + Post chains are correct,
and refresh docs (`PROGRESS.md`, migration notes). Appliance xrun soak is
`blocked-verify` — CI proves logic, not device soak.

## Problem Statement / Motivation

Core path may work in harness/UI tests while undo/export/monitor-sum edge cases
still lie. Shipping without these leaves silent stem wrongness and surprising
clear/undo behavior.

## Proposed Solution

### Contracts to lock in tests

| Topic | Behavior |
|-------|----------|
| Clear track | Clears PCM (+ existing undo rules); **keeps** Pre/Post + Live Signal |
| Undo after Pre overdub | Restores prior PCM layer; Post racks unchanged |
| Mid-record Pre edit | Subsequent frames use new params (P7) |
| Multi Live Signal On | **Sum** contributions; soft warn when over budget (UI toast/banner via existing toast path) |
| Input Post vs dry send | Input Post colors the **wet monitor / FOH** path only; dry send (`setMonitorDry` / dry mask) stays FX-free — never run Input Post into the dry send |

### Export (`daw_export`)

- Pre already in PCM → stems reflect printed audio
- Post chains in **manifest JSON** (opaque / own-input model — **do not** import
  `looper_repository` / `loopy_engine` types into `daw_export`)
- Extend `packages/daw_export/lib/src/fx_chains.dart` + writer tests

### Docs

- Update `docs/PROGRESS.md` FX mental model (retire snapshot-primary)
- Migration default (Input/Lane → Post) in release notes section
- Appliance preset/CPU notes in `docs/RUNNING_ON_RPI.md` if needed

### Tasks

- [ ] Engine/repo tests: clear-keeps-racks, undo+Pre overdub, mid-record Pre
- [ ] Multi Live Signal On sum + soft-limit warning path
- [ ] Reconcile Input Post with dry/wet monitor masks
- [ ] `daw_export` Pre-in-PCM + Post manifest
- [ ] Docs updates
- [ ] Manual happy-path listen checklist on #351 (desktop or appliance)

## Technical Considerations

- **Architecture:** Keep export package dependency-free of looper domain types.
- **Performance:** Soft CPU limit — warn, don’t hard-fail audio.
- **Security:** N/A.

## Success Criteria

```success-criteria
GOAL: Pre/Post edge contracts are tested; export manifests match Pre-baked PCM + Post chains; docs reflect the new mental model.

SUCCESS CRITERIA:
- Native/domain tests cover clear-keeps-FX and Pre overdub undo | verify: bash packages/loopy_engine/src/test/run_native_tests.sh && cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test --name "clear|undo|PrePost|LiveSignal"
- daw_export tests cover Pre-baked + Post manifest fields without importing looper_repository | verify: cd packages/daw_export && /Users/Tomas/development/flutter/bin/flutter test --name "pre post|FxRack|fx-chains|manifest" && ! rg -n "package:looper_repository|package:loopy_engine" packages/daw_export/lib
- PROGRESS.md documents Pre/Post + Live Signal as primary FX model | verify: rg -n "Pre/Post|Live Signal|snapshot-on-record" docs/PROGRESS.md
- Happy path manual listen | verify: manual 1) In2→Track1 Pre delay + Post reverb + Live Signal Auto 2) record 3) bypass Post 4) confirm delay remains, reverb gone
- Appliance multi Live Signal On soak | verify: manual blocked-verify on device — document xrun outcome on #351 (not merge-blocking for desktop CI)

NON-GOALS:
- Pedal/expression, Bounce As Loop, per-lane overrides (Phase 5 child issues)
- Factory content authorship (part 4)
- Pixel UI polish beyond contract clarity

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh && cd packages/daw_export && /Users/Tomas/development/flutter/bin/flutter test --name "pre post|FxRack|fx-chains|manifest"
```

## Success Metrics

- Export stems usable in a DAW without surprise dry/wet mismatch
- Clear/undo do not wipe rack configuration
- Epic #351 checklist for parts 1–5 can be completed

## Dependencies & Risks

- Parts 1–3 required
- Appliance soak = `autonomy:blocked-verify` slice — do not block desktop merge
- Export manifest shape changes may need performance_repository consumers updated
  if they parse FX summaries

## References & Research

- Epic Phase 4 + success criteria
- `packages/daw_export/lib/src/fx_chains.dart`
- `docs/PROGRESS.md`
- Parts 1–3 plans
