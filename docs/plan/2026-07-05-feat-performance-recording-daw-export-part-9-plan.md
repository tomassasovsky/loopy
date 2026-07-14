---
title: "feat: performance recording — part 9: daw_export core (.als builder + corpus)"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 9: daw_export core (.als builder + corpus) — Standard

> **Split note:** part 9 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). **Pure Dart,
> fixture-driven, parallel** to the native track (parts 5–8): it depends only
> on the pinned data formats (event log, part 3; manifest, part 6), not on
> real renders. A good first-contributor part.

## Overview

New pure-Dart `daw_export` package that generates an **Ableton Live 12**
`.als` set (gzipped XML, generated directly — no Ableton needed): one audio
track per non-empty Loopy track + one per live-input stem; arrangement-view
clips at capture t=0 (full-length stems make placement trivial and
sample-accurate); session-view loop clips per lane; **fixed 120 BPM, warp OFF
on every clip** (D-TEMPO); **relative file references only** so the bundle
stays self-contained (D-ALS). Development is corpus-driven: a committed set
of minimal Live 12 projects, using the "save from Live, diff the XML"
methodology.

## Context / findings

- **Own input model, no upstream imports:** `daw_export` defines
  `DawProject` / `DawTrack` / `DawClip` (+ `AutomationLane` in part 10) and
  consumes the documented `performance.json` + event-log formats — it never
  imports `performance_repository` or `loopy_engine` (dependency-direction
  rule). The app layer maps manifest → `DawProject` (part 11).
- `.als` structure facts (research): gzipped XML; internal `Id`/`Pointee`
  references must stay consistent; `FileRef` paths drive the missing-file
  dialog; `AudioTrack`/`MainTrack` elements; tempo lives in the main track's
  automation envelope (PointeeId 8). Validate by diffing generated output
  against corpus saves and re-opening in Live 12.
- Pure Dart package (no Flutter SDK dep) so tests run anywhere; gzip via
  `dart:io`'s `GZipCodec`, XML via hand-rolled builder or `xml` package (pick
  in-implementation; corpus tests are the contract).
- Live 11 behavior (may refuse a 12 set) documented in the README as a known
  limitation (user-locked D-ALS).

## Acceptance Criteria

- [ ] `buildAls(DawProject)` emits gzipped XML that round-trips (decompress →
      parse → structural assertions) with unique, consistent `Id`/`Pointee`
      references (test).
- [ ] Every `FileRef` is **relative**; an absolute path in any fixture output
      fails the suite (test).
- [ ] Arrangement clips: correct start positions/lengths in seconds-derived
      beat units at fixed 120 BPM; **warp off** asserted on every clip
      (test).
- [ ] Session-view slots: one loop clip per (track, lane) fixture entry
      (test).
- [ ] Track layout: one audio track per non-empty Loopy track + one per
      live-input stem; empty tracks skipped (test).
- [ ] Corpus committed (`packages/daw_export/test/corpus/`) with a README
      documenting the save-from-Live/diff methodology and the Live 12
      version used.
- [ ] Manual gate (recorded in the PR): a generated fixture project opens in
      Live 12 with no missing-file dialog, correct track/clip layout; moving
      the folder keeps refs resolving.
- [ ] Coverage ≥ 90; `flutter analyze` clean; format stable.

## Tasks

- [ ] `packages/daw_export/` scaffold (pure Dart) + `DawProject`/`DawTrack`/
      `DawClip` model.
- [ ] Manifest/log readers for the documented formats (fixture-driven).
- [ ] Live 12 XML skeleton builder (Id/Pointee allocator, MainTrack, tempo
      envelope at 120, transport).
- [ ] Audio track + arrangement clip + session clip emitters (warp off,
      relative `FileRef`s).
- [ ] Gzip writer (`project.als`).
- [ ] Corpus + structural test suite; README methodology.

## Files touched (primary)

`packages/daw_export/*` (new package),
`packages/daw_export/test/corpus/*` (committed Live 12 samples).

## Verification

1. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
2. `flutter test packages/daw_export` — green, coverage ≥ 90.
3. Manual: open a generated fixture `.als` in Live 12 (checklist in PR).

## Dependencies

- **Part 3** (event-log format doc) and **Part 6** (manifest schema doc) —
  formats only, not code. Fully parallel with parts 5–8.
