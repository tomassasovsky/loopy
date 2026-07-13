---
title: docs: bring PROGRESS.md current (performance recording, DAW export, VST3 plugins)
type: fix
date: 2026-07-13
---

## docs: bring PROGRESS.md current - Standard

## Overview

`docs/PROGRESS.md` is the project's living status doc, and `CONTRIBUTING.md`
mandates it be updated in the same change a piece of work lands ("move the
item from Roadmap -> Done ... this is how progress survives across
sessions"). That mandate has drifted for three shipped feature areas —
**performance recording** (12-part plan, PRs through #136), **DAW export**
(`daw_export` package, PRs #132/#133/#146), and **VST3 plugins** (both
third-party plugin *hosting*, and Loopy's own effects shipped *as* VST3
plugins for DAWs, PRs #137-#162 and beyond) — plus general test-count drift
in packages that already had entries. This plan brings `docs/PROGRESS.md`
current against `git log` and the actual `packages/` tree, and corrects one
actively stale claim (that a VST3 host "remains a gated follow-up" when it
has since shipped on macOS + Windows).

This is a **docs-only** change to a single file: `docs/PROGRESS.md`. No
source code changes. Out of scope: the stale native-engine-test build
command in the "How to build/test" section (owned by a separate, parallel
fix — do not touch it).

## Problem Statement / Motivation

A session or contributor resuming from `docs/PROGRESS.md` alone would not
know performance recording, DAW export, or VST3 plugins exist — 8 of the
repo's 13 `packages/*` directories aren't in the Architecture list, none of
the three feature areas appear in "Done", and the "Test counts (last green)"
section is missing entries for the new packages while several existing
entries have silently drifted (e.g. `session_repository` documented as 17,
actually 57). Worse, the existing "Effects chain" Done bullet says a VST3/
CLAP host "remains a gated follow-up (needs the SDK vendored to compile ...)"
— which was true when written but is now false; the host has been vendored,
built, and shipped on macOS and Windows. Leaving it means the doc actively
misleads rather than merely omits.

## Proposed Solution

Edit `docs/PROGRESS.md` in four places, matching the doc's existing voice and
density (Architecture = one line per package; Done = one prose paragraph per
shipped feature; Roadmap = short bullets; Test counts = terse per-package
tally):

1. **Architecture package tree** — add the 8 missing packages as one-line
   entries in the existing `packages/` tree block (same `NAME  TAG —
   description` style as the 5 already listed): `daw_export`, `midi_client`,
   `midi_device_repository`, `pedal_repository`, `performance_repository`,
   `routing_graph`, `session_repository`, `wav_codec`.

2. **Done section** — add two new bullets (following the existing pattern of
   folding a multi-PR arc into one bullet, e.g. "Multi-lane routing UI (PR
   5)"):
   - **Performance recording + DAW export**: sample-accurate capture-to-disk
     of a live performance (audio-thread taps → lock-free rings → drain
     thread → event log), the `wav_codec` + `performance_repository`
     packages, recorder UI/app state, pedal-firmware arm/disarm parity (MODE
     tap-vs-hold); and the `daw_export` package turning a capture into an
     Ableton Live 12 `.als` project (audio tracks, session/arrangement clips,
     volume + mute automation envelopes, and real Loopy VST3 device chains
     embedded when a track's per-lane effects resolve cleanly, wet-bounce
     stem as the sole fallback).
   - **First**, in place: correct the existing "Effects chain" bullet's stale
     closing sentence to state plugin hosting (loading third-party VST3/CLAP
     plugins as effects) has shipped on macOS and Windows (scan/catalog, slot
     lifecycle, dynamic parameter UI, native editor windows), with Linux
     (X11) hosting the one remaining gap.
   - **Then, one new bullet** (matching the rest of Done's one-bullet-per-
     feature density — no (a)/(b) sub-structure): Loopy's own built-in
     effects shipped *as* installable VST3 plugins for third-party DAWs — 7
     native macOS plugins (Delay, Reverb, Echo, Drive, Filter, Tremolo,
     Octaver), a golden-parity audio-diff harness, a portable CMake + CTest
     gate, and Windows + Linux builds of those same 7 plugins; parts 15-17 of
     that plan are brainstormed only
     (`docs/brainstorm/2026-07-13-vst3-plugins-parts-15-17-brainstorm-doc.md`),
     not built.

3. **Roadmap section** — update/add bullets noting the two concrete
   remaining gaps: VST3 plugin-hosting's Linux (X11) port, and VST3-FX-plugin
   parts 15-17 (brainstormed, not built). Correct any existing Roadmap
   language that implies plugin work is still blocked wholesale.

4. **Test counts (last green)** — refresh the whole section: add the 6
   missing packages and refresh the numbers for 4 existing entries that had
   drifted, all freshly re-run and green in this session:
   - New: `wav_codec` 5, `daw_export` 79, `performance_repository` 56,
     `pedal_repository` 116, `midi_device_repository` 22, `routing_graph` 45.
   - Refreshed: `controller_repository` 18 (was 14), `settings_repository`
     65 (was 63), `session_repository` 57 (was 17), `loopy_engine` (dart-level;
     the doc's old "plugin" label) 138 with ~7 skipped (was "plugin 38"),
     `app` 737 with ~13 skipped excl. screenshots-tagged goldens (was 358).
   - Unchanged: `local_storage_client` 1.
   - **Not re-run**: the native C engine test count and the VST3 CTest gate
     count. The documented native build command is itself stale (separate,
     parallel fix); running/fixing it is out of scope here. Describe native/
     VST3-CTest coverage narratively (what they cover, e.g. the VST3 CTest
     gate wiring "16 tests: 7 plugin-id + 7 parity + 2 wrapper, plus a
     per-plugin load-smoke gate" per PR #159's own description) rather than
     with a number obtained by executing the stale command.

## Technical Considerations

- **No code or test changes** — pure markdown edit to one file.
- **Scope containment**: only `docs/PROGRESS.md` is modified by this plan.
  (The brainstorm and this plan file are new files under `docs/brainstorm/`
  and `docs/plan/`, which is normal for this workflow, not scope creep.)
- **Don't touch the "How to build/test" section's native-test clang command**
  — a separate, parallel agent owns that specific stale-command fix; touching
  it risks a merge collision / duplicated work.
- **Keep existing structure and headings** — no new top-level `##` sections,
  no reordering of existing content; only extend the 4 sections named above
  in place, in the same style as neighboring entries.
- **cspell**: CI runs a spell-check job (`VeryGoodOpenSource/very_good_workflows
  spell_check.yml`) against `.github/cspell.json` over all `.md` files. New
  vocabulary this plan introduces (`.als`, `Ableton`, `daw_export`, `VST3`,
  `CLAP`, `octaver`, `dlopen`, `ctest`) already appears elsewhere in the
  committed repo (`docs/design/performance-event-log-format.md`,
  `docs/plan/2026-06-23-feat-vst3-clap-plugin-hosting-plan.md`,
  `.github/cspell.json`'s own word list), so no new unknown-word failures are
  expected. This sandbox's `cspell` invocation with `--config` returns "0
  files checked" (likely no network access to the config's remote
  dictionaries here), so the actual CI spell-check gate can't be executed
  locally — confirmed green by the PR's CI run instead, not treated as a
  local success criterion.
- **Parallel-fix boundary**: the "How to build/test" section's native-test
  clang command block is owned by a separate, parallel fix. This plan does
  not touch it; a final `git diff` of that section against `origin/master`
  should show no change, checked by eye before opening the PR rather than as
  a scripted criterion.

## Success Criteria

```success-criteria
GOAL: docs/PROGRESS.md accurately reflects all shipped work (performance
recording, DAW export, VST3 plugins/hosting) in its Architecture, Done,
Roadmap, and Test-counts sections, with no other file touched.

SUCCESS CRITERIA:
- All 13 packages/* directories are named in the Architecture section | verify: for p in loopy_engine controller_repository looper_repository settings_repository local_storage_client daw_export midi_client midi_device_repository pedal_repository performance_repository routing_graph session_repository wav_codec; do grep -q "$p" docs/PROGRESS.md || { echo "MISSING $p"; exit 1; }; done
- Done section mentions performance recording | verify: grep -qi "performance recording" docs/PROGRESS.md
- Done section mentions DAW export / .als | verify: grep -qi "daw_export\|\.als" docs/PROGRESS.md
- Done section mentions the shipped VST3 FX plugins (Delay/Reverb/Echo/Drive/Filter/Tremolo/Octaver) | verify: grep -qi "octaver" docs/PROGRESS.md
- The stale "gated follow-up" claim about plugin hosting being blocked is removed | verify: ! grep -q "it remains a gated follow-up (needs the SDK vendored to compile" docs/PROGRESS.md
- Test counts section lists the 6 newly-tested packages | verify: for p in wav_codec daw_export performance_repository pedal_repository midi_device_repository routing_graph; do grep -q "$p" docs/PROGRESS.md || { echo "MISSING $p"; exit 1; }; done
- Only docs/PROGRESS.md is modified (tracked-file diff) | verify: test "$(git diff --name-only)" = "docs/PROGRESS.md"
- Existing top-level section headings are preserved (no structural rewrite) | verify: for h in "## How to build" "## Architecture" "## Done" "## Locked design decisions" "## Roadmap" "## Test counts"; do grep -q "$h" docs/PROGRESS.md || { echo "MISSING HEADING $h"; exit 1; }; done

NON-GOALS:
- Fixing the stale native-engine-test build command (separate parallel fix).
- Re-running or fixing the native C engine test suite or the VST3 CTest gate.
- Any source code, test, or non-PROGRESS.md doc change.
- Reconciling the two plans' inconsistent internal part-numbering schemes.

VERIFICATION COMMAND: for p in loopy_engine controller_repository looper_repository settings_repository local_storage_client daw_export midi_client midi_device_repository pedal_repository performance_repository routing_graph session_repository wav_codec; do grep -q "$p" docs/PROGRESS.md || exit 1; done && grep -qi "performance recording" docs/PROGRESS.md && grep -qi "daw_export\|\.als" docs/PROGRESS.md && grep -qi "octaver" docs/PROGRESS.md && ! grep -q "it remains a gated follow-up (needs the SDK vendored to compile" docs/PROGRESS.md && for p in wav_codec daw_export performance_repository pedal_repository midi_device_repository routing_graph; do grep -q "$p" docs/PROGRESS.md || exit 1; done && test "$(git diff --name-only)" = "docs/PROGRESS.md"
```

## Success Metrics

- A cold session reading only `docs/PROGRESS.md` can correctly answer "does
  Loopy have performance recording / DAW export / VST3 plugin support?" for
  all three, with no contradictions between bullets.
- `docs/PROGRESS.md`'s package tree and `ls packages/` agree on package
  existence.

## Dependencies & Risks

- **Merge collision risk**: a separate, parallel agent is fixing the stale
  native-test build command elsewhere in the same file. Keeping this plan's
  edits confined to the 4 named sections (Architecture, Done, Roadmap, Test
  counts) and leaving the "How to build/test" command block untouched
  minimizes overlap.
- **Risk of over-editing**: the temptation to also fix unrelated drift (e.g.
  other stale claims elsewhere in the 567-line doc) is real given how much
  has shipped; scope is deliberately capped to the 3 named feature areas +
  the one directly-contradicting stale sentence they touch.

## References & Research

- Brainstorm: `docs/brainstorm/2026-07-13-progress-md-docs-drift-brainstorm-doc.md`
- `CONTRIBUTING.md` lines 8-11 (the "keep PROGRESS.md current" mandate).
- Performance recording commits: `10d91da`, `62a2f82`, `e309a74`, `1b8aa7b`,
  `5d019ed`, `6f22a7a`, `1479723`, `dc82b24` (PRs up to #136).
- DAW export commits: `5d019ed` (#132), `6f22a7a` (#133), `faccf96` (#146).
- VST3 plugin-hosting commits: `6d8a68b`, `786f428`, `9ff79bb`, `cfaf5f6`,
  `db7d4c5`, `658ae83`, `24167bf`, `0ecf933` (Windows part 8).
- VST3 own-FX-plugins commits: `9425a4e`, `8e94425`, `169ea8b`, `d4c3849`,
  `030ea0d`, `e177da6`, `a59a9e7`, `a2e03e1`, `ad24a50`, `faccf96`, `7ab1053`
  (#159), `1df2715` (#160, Windows), `87085e3` (#161, Linux), `659090d`
  (#162), `f3f5b76` (#167, parts 15-17 brainstorm).
- Package contents verified directly: `packages/daw_export/lib/src/`,
  `packages/performance_repository/lib/src/`, `packages/loopy_engine/vst3/`.
- Test counts re-run this session (all green) — see Proposed Solution §4 for
  the exact per-package numbers.
