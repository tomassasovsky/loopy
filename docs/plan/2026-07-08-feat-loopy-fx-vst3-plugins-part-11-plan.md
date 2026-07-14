---
title: "feat(app): export-flow device-chain feedback + re-export (part 11)"
type: feat
date: 2026-07-08
part: 11 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 11 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-REEXPORT) lives in the umbrella. **Replaces the
> original part 6's toggle framing** — there is no longer a user-facing
> choice between two export modes (the stock-device path this toggle used to
> switch away from was dropped, part 10), so this part instead surfaces
> *why* a given track's export landed where it did, plus the still-valid
> re-export recovery action.

## Dependencies

Part 10 (`DawTrack.deviceChain`/`deviceChainFallbackReason` must exist to
surface).

## Overview

Two additions to the app layer, both scoped to the performance-export flow
(`lib/performance/`):

1. A **per-track export summary** shown on the performance-completion
   surface (the sheet shown after a capture finalizes, per the
   performance-recording feature's `PerformanceCompletionSheet`): for each
   exported track, state whether it exported with live Loopy plugin devices
   or bounced audio, and — when it bounced **because** effects existed but
   couldn't be represented ([D-CHAIN-FALLBACK](../2026-07-08-feat-loopy-fx-vst3-plugins-plan.md#decisions))
   — the specific reason (mixed lane effects chains, a third-party hosted
   plugin, or an unrepresented effect type). A track with no effects at all
   gets no fallback callout — there's nothing to explain. This directly
   serves the "honest degrade" principle: a user shouldn't have to open the
   `.als` in Ableton to discover a track silently lost its live device
   chain.
2. A **re-export** action, unchanged in purpose from the original part 6:
   today's export is a one-shot side effect of capture finalize
   ([performance_recorder_cubit.dart](../../lib/performance/cubit/performance_recorder_cubit.dart)),
   so if a user installs Loopy's plugins *after* already exporting (getting
   the wet-bounce fallback because the plugins weren't the reason for
   fallback — device-chain resolution doesn't depend on local plugin
   installation at export time, only on the manifest's own effects data,
   but a user may still want a fresh corpus/GUID after a Loopy update, or
   simply to re-run generation without re-recording for any reason), this
   adds a lightweight action that re-runs `.als` + `fx-chains.txt`
   generation from the performance's already-persisted capture directory
   (audio files untouched, no re-render needed).

## Tasks

- [ ] New `ExportDeviceChainSummary` widget (extracted class, not a
  `_build` method, per VGV convention) in the performance-completion view:
  one row per exported track, an icon/label distinguishing "live plugins"
  vs. "bounced audio," and the fallback reason when applicable.
- [ ] Fallback-reason copy component: three distinct, specific messages
  (mixed lane chains, third-party plugin, unrepresented effect type) — not
  one generic "couldn't export effects" string, so a user has enough
  information to know whether the fix is in their control (e.g. making lane
  chains match) or not (a third-party plugin, which stays out of scope).
- [ ] New l10n keys in `app_en.arb` **and** `app_es.arb` with `@`-metadata:
  the summary row labels and all three fallback-reason messages.
- [ ] `PerformanceRecorderCubit` (or the relevant repository) gains a
  `reExport(slug)` entry point that reads the existing `performance.json`
  manifest for a finalized capture directory and re-invokes the
  `daw_export` build step only — no engine, no re-render, no audio-file
  writes.
- [ ] Widget/bloc tests: summary renders the correct live-vs-bounced state
  and fallback reason per track from a `DawProject` fixture; re-export
  triggers regeneration without touching audio files (assert the
  stems/master WAVs are untouched — mtime or content check).

## File References

- `lib/performance/cubit/performance_recorder_cubit.dart` (re-export entry point)
- `lib/performance/view/` (completion sheet + new `ExportDeviceChainSummary` widget)
- `packages/daw_export`'s `DawTrack.deviceChain`/`deviceChainFallbackReason` (part 10, consumed here)
- `app_en.arb`, `app_es.arb` (new l10n keys)

## Acceptance Criteria

- [ ] The export/completion flow shows a per-track summary distinguishing
  live-plugin exports from bounced-audio exports, with a specific reason
  shown for each of the three fallback cases.
- [ ] Re-export regenerates `.als`/`fx-chains.txt` from a persisted capture
  directory without re-recording or touching audio files.
- [ ] `bloc_test` coverage for every new state transition (summary
  computed, re-export start/success/failure).
- [ ] Widget tests for `ExportDeviceChainSummary` covering all three
  fallback reasons plus the no-effects (no callout) case.
- [ ] `app_en.arb`/`app_es.arb` both updated with `@`-metadata for every new
  key.

## Out of Scope

Any change to the underlying render/capture pipeline; a user-facing toggle
to force bounced-audio export even when a device chain would resolve
(not requested by the brainstorm — the export is automatic, not a choice).
