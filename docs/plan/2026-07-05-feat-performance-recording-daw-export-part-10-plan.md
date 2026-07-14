---
title: "feat: performance recording — part 10: daw_export automation + fx-chains"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 10: daw_export automation + fx-chains — Standard

> **Split note:** part 10 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). Completes the
> `daw_export` package: automation envelopes from the raw event log, and the
> human-readable FX summary.

## Overview

Map logged performance gestures into the `.als`: volume events → **mixer
volume automation** envelopes; mute events → **track-activator automation**
(Ableton has no native "mute automation"; the activator parameter preserves
the gesture rather than baking it into clip splits — D-MUTE). **Breakpoint
thinning lives here and only here** (the capture path stores the raw log;
umbrella D-LOG): continuous sweeps are thinned to bounded breakpoint density
with exact first/last values. Also emit `fx-chains.txt` — the human summary
generated from the manifest's canonical FX metadata, including third-party
plugin identity and the offline "rendered as passthrough" notes from part 8.

## Context / findings

- `AutomationLane` joins the `DawProject` model; envelopes attach to the
  mixer volume and activator parameters with correct `Pointee` wiring
  (corpus-verify the envelope shape — automation XML is the fiddliest part of
  the schema, per the research pass).
- Thinning algorithm: keep breakpoints such that linear interpolation stays
  within an epsilon of the raw curve, capped at a max density (~30/s);
  always keep first/last and step discontinuities (mute toggles are steps,
  not ramps).
- `fx-chains.txt` renders per track/lane: chain order, effect names,
  normalized params, plugin identity (`format + id + version`) for
  `PluginEffect` entries, and passthrough annotations. `performance.json`
  remains the canonical machine-readable record (umbrella — no `.als`
  annotation mirroring).

## Acceptance Criteria

- [ ] A fixture log with a volume ride yields a mixer-volume envelope whose
      thinned breakpoints stay within epsilon of the raw curve, with exact
      endpoints (test).
- [ ] Mute toggles yield step-shaped activator automation at the exact event
      beats (test).
- [ ] Thinning density is bounded (≤ ~30 breakpoints/s) for a 1 kHz sweep
      fixture (test).
- [ ] Envelope XML passes the corpus structural checks (Pointee wiring,
      parameter targets) (test).
- [ ] `fx-chains.txt` content matches a fixture manifest, including plugin
      identity + passthrough notes (test).
- [ ] Manual gate: automation visibly present and correct on a generated
      project opened in Live 12.
- [ ] Coverage ≥ 90 held; `flutter analyze` clean; format stable.

## Tasks

- [ ] `AutomationLane` model + envelope XML emitters (mixer volume,
      activator) with Pointee wiring.
- [ ] Thinning algorithm + unit tests (epsilon, density cap, steps,
      endpoints).
- [ ] Log → envelope mapping (volume, mute) in the manifest/log reader layer.
- [ ] `fx-chains.txt` generator from manifest FX metadata.
- [ ] Corpus additions: a Live 12 save containing volume + activator
      automation to diff against.

## Files touched (primary)

`packages/daw_export/lib/src/*`, `packages/daw_export/test/*`,
`packages/daw_export/test/corpus/*`.

## Verification

1. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
2. `flutter test packages/daw_export` — green, coverage ≥ 90.
3. Manual: automation check in Live 12 (checklist in PR).

## Dependencies

- **Part 9** (`daw_export` core).
