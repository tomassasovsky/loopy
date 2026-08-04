# Plan: Rebrand Loopy → Segno

Closes tracking: [#247](https://github.com/tomassasovsky/loopy/issues/247).

## Decision

Product name is **Segno** (SMuFL segno glyph U+E047 / Bravura). Avoids collision
with Loopy / Loopy Pro (A Tasty Pixel). Update host `segno.aquiles.dev` already
existed ahead of this rename.

## Mapping

| Before | After |
|--------|--------|
| package `loopy` | `segno` |
| `loopy_engine` | `segno_engine` |
| `dev.loopy.loopy` (+`.dev`/`.stg`) | `dev.aquiles.segno` |
| `.loopy` sessions | `.segno` (no backward compat) |
| appliance `loopy-*` ctl/units | `segno-*` |
| display "Loopy" | "Segno" / `[DEV] Segno` / `[STG] Segno` |
| USB product `VAMP Loopstation` | `Segno Loopstation` |
| enclosure `vamp_*` parts / fab zips | `segno_*` |

`Looper` / `looper` (feature vocabulary) intentionally unchanged.

## Icons

- Glyph: Bravura U+E047, rendered to Icon Composer `Logo.svg` + Android mipmaps
  + Windows `.ico` + Plymouth lockup.
- Prod: clean glyph, no badge.
- Dev / staging: bottom `DEV` / `STG` banner on Android + Icon Composer
  `Badge.png`; macOS/iOS `FLAVOR_APP_NAME` prefixes `[DEV]` / `[STG]`.

## Out of scope / follow-ups

- GitHub repo rename `tomassasovsky/loopy` → `tomassasovsky/segno` (redirects).
- Local checkout directory name (`.../loopy`).
- Published store listings / signing identities if any already use the old id.
