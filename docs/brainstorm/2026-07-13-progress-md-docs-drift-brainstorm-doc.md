---
date: 2026-07-13
topic: progress-md-docs-drift
---

# docs/PROGRESS.md drift — performance recording, DAW export, VST3 plugins

## What We're Building

Not a code change — a documentation catch-up. `docs/PROGRESS.md` is the
project's "living status doc," and `CONTRIBUTING.md` mandates it be updated
"in the same change" a piece of work lands ("move the item from Roadmap ->
Done ... this is how progress survives across sessions"). That mandate has
been violated for three large, already-shipped feature areas:

1. **Performance recording** (a 12-part plan, commits `10d91da`..`dc82b24`,
   PRs up to #136): sample-accurate capture-to-disk of a live performance
   (audio-thread taps → lock-free rings → drain thread → event log),
   `wav_codec` + `performance_repository` packages, recorder UI/app state, and
   pedal-firmware arm/disarm parity (MODE-button tap-vs-hold).
2. **DAW export** (parts 9-10 of what became a combined 17-part
   performance-recording + DAW-export + VST3 plan; PRs #132, #133, #146): a
   new `daw_export` package that turns a performance capture into an Ableton
   Live 12 `.als` project — audio tracks, session/arrangement clips, volume +
   mute automation envelopes, and (the newest piece) real Loopy VST3 device
   chains embedded in the `.als` when a track's per-lane effects resolve
   cleanly, falling back to a wet-bounce stem otherwise.
3. **VST3 plugins**, which is really two related but distinct threads that
   both need to appear:
   - **Plugin hosting** (loading third-party VST3/CLAP plugins into Loopy as
     effects) — vendored SDKs, scan/catalog, slot lifecycle, dynamic
     parameter UI, native editor windows on **macOS and Windows**; Linux
     (X11) hosting is the one part still not shipped.
   - **Loopy's own built-in effects, exported as installable VST3 plugins**
     for third-party DAWs (a separate, newer plan) — 7 native macOS plugins
     shipped (Delay, Reverb, Echo, Drive, Filter, Tremolo, Octaver), a
     golden-parity audio-diff harness proving DSP parity with the engine,
     a portable CMake + CTest gate, and Windows + Linux builds of those same
     7 plugins (parts 13/14 of a renumbered 17-part plan). Parts 15-17 are
     only brainstormed (`docs/brainstorm/2026-07-13-vst3-plugins-parts-15-17-brainstorm-doc.md`),
     not built yet.

None of this appears in PROGRESS.md's Architecture package list (which is
missing 8 of the repo's 13 `packages/*` directories:
`daw_export`, `midi_client`, `midi_device_repository`, `pedal_repository`,
`performance_repository`, `routing_graph`, `session_repository`,
`wav_codec`), its "Done" section, or its "Test counts (last green)" section.
Worse, the existing "Effects chain" Done entry contains an actively **stale**
claim — it says a plugin host "remains a gated follow-up (needs the SDK
vendored to compile...)" when the host has since been vendored, built, and
shipped (macOS + Windows). A cold-resuming session or agent reading only
PROGRESS.md would not just miss these features — it would be actively misled
about plugin hosting's status.

## Why This Approach

This is a pure documentation-fidelity fix: read the doc's existing
conventions (Architecture tree = one line per package; Done = one bullet per
shipped feature, at whatever technical depth that feature's own commit
messages/plan docs support; Test counts = a terse per-package tally) and
extend them with the same voice, rather than restructuring the doc. No
alternative approaches were seriously considered — the fix is dictated by
the doc's own existing format, and the job is to fill the gap accurately, not
redesign the format.

The one real decision is **how much to touch stale content beyond pure
addition**. Three sub-decisions, each with an assumption recorded since there
is no live user to ask:

- **Assumption A — correct the stale "gated follow-up" sentence in the
  existing "Effects chain" Done bullet.** Leaving it as-is would mean the doc
  contradicts itself (says host is blocked right next to a new bullet saying
  it shipped). Since CONTRIBUTING.md's mandate is about accuracy, not just
  addition, this in-place correction is treated as in-scope and narrowly
  targeted (one sentence, not a rewrite of the whole bullet).
- **Assumption B — refresh existing "Test counts (last green)" numbers for
  packages already listed, not just add missing ones.** Re-running the
  existing package suites (controller_repository, settings_repository,
  session_repository) turned up drift there too (e.g. session_repository:
  documented 17, actually 57) — almost certainly from unrelated work landing
  without the "bump test counts" half of the CONTRIBUTING mandate either.
  Since the section is being touched anyway and the numbers were cheap to
  re-derive (all Dart suites run in seconds), refresh all of them for
  internal consistency rather than leave known-wrong numbers next to
  newly-added correct ones. The **native C engine test count and the VST3
  CTest gate count are explicitly NOT re-derived by running them** — the
  documented native build command in the "How to build/test" section is
  itself stale (a separate, parallel fix owns that); running it would either
  fail or require touching that command, which is out of scope here. Native/
  VST3-CTest coverage is described narratively (what they cover) rather than
  with a freshly-executed number, consistent with how the doc already
  describes native coverage without a hard count in several places.
- **Assumption C — do not attempt to reconcile part numbers across the two
  renumbered plans** (12-part performance/DAW-export plan vs. the
  12-part-then-17-part VST3 plan whose numbering shifted mid-flight — e.g.
  "Reverb — part 3/12" vs. "Echo — part 5/17" for adjacent commits). The Done
  section will describe features by name/content, mentioning part numbers
  only where a single commit's own message states one, rather than trying to
  produce a globally consistent part-count narrative the original commits
  themselves don't have.

## Key Decisions

- **Scope stays to `docs/PROGRESS.md`** (Architecture, Done, Roadmap, Test
  counts). No source code, no other doc files, no touching the stale native
  test-build command (owned by a parallel fix).
- **Ground truth = `git log --oneline` + `ls packages/` + reading the actual
  package `lib/src/` contents + running each package's own test suite once**,
  not the (possibly stale) issue description, which explicitly warns more has
  shipped since it was written.
- **Test counts**: re-run and refresh all Dart package suites (cheap, all
  green): `wav_codec` 5, `daw_export` 79, `performance_repository` 56,
  `pedal_repository` 116, `midi_device_repository` 22, `routing_graph` 45,
  `controller_repository` 18 (was 14), `settings_repository` 65 (was 63),
  `session_repository` 57 (was 17), `local_storage_client` 1 (unchanged),
  `loopy_engine` (dart-level) 138 with ~7 skipped (was documented as
  "plugin 38" — an old label for the same suite). The main `app` suite is
  being re-verified; if it doesn't come back clean and fast, its count will
  be left as the last-known-green figure with a note rather than blocked on
  fixing an unrelated failure. Native C engine tests and the VST3 CTest gate
  are described narratively (feature coverage), not with a rerun number,
  per Assumption B above.
- **New Architecture entries** for the 8 missing packages, one line each in
  the existing tree-list style (package name, "DATA/REPO" tag where the
  existing convention uses one, one-clause description).
- **New Done entries**, roughly one paragraph each: Performance recording
  (folding the 12 parts into one narrative bullet, the way e.g. "Multi-lane
  routing UI (PR 5)" already folds a multi-PR arc into one bullet), DAW
  export (folded with it or adjacent, since the two plans merged and the
  device-chain-resolver piece depends on both), Plugin hosting status
  correction + Loopy-FX-as-VST3-plugins (separate bullet, since it's a
  distinct deliverable from the host).
- **Roadmap update**: note VST3 plugin-hosting's one remaining gap (Linux X11
  host) and the VST3-FX-plugins plan's remaining parts 15-17 (brainstormed,
  not built) as open items, replacing/updating whatever the Roadmap currently
  implies about plugin work being blocked.

## Open Questions

- None blocking. The only soft judgment call is exactly how much prose each
  new Done bullet deserves — resolved by matching the density of neighboring
  existing bullets (detailed, but not longer than the longest existing entry,
  e.g. "Unified input FX & routing").
