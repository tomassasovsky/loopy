---
title: "feat(vst3): macOS code signing + notarization, all seven plugins (part 12)"
type: feat
date: 2026-07-08
part: 12 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 12 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-SIGN) lives in the umbrella. Formerly part 7
> (signed Delay + Reverb only) — **scope widened** to all seven plugin
> bundles now that Drive/Filter/Tremolo/Octaver/Echo exist (parts 5-9).
> Upgrades every `.vst3` bundle from ad-hoc dev signing to real Developer ID
> + notarization, required before part 15's installer can distribute them.

## Dependencies

Parts 2, 3, 5, 6, 7, 8, 9 (all seven bundles must build before signing all
seven).

## Overview

All seven `.vst3` bundles currently ad-hoc sign (`codesign -f -s -`) for
local dev use. Each needs **its own** Developer ID signature, independent
of whatever eventually signs the app installer (umbrella D-SIGN) — hardened
runtime is required for notarization eligibility. Per research: if the
plugins ship **inside** a notarized `.pkg`/`.dmg` (part 15), only the
outermost installer needs `notarytool submit` — a separate `stapler staple`
on each `.vst3` isn't required in that flow, but every bundle must still
carry a valid Developer ID signature with hardened runtime turned on, or the
installer's own notarization can fail / a plugin can still be rejected by
Gatekeeper when unpacked and scanned by a DAW. Confirmed real-world pitfall:
macOS Gatekeeper specifically flags unsigned/unnotarized VST3s when a DAW
scans them, and the usual `.app` "right-click → Open" bypass does not work
for bare plugin bundles.

## Tasks

- [ ] Replace the ad-hoc `codesign -f -s -` post-build step (parts 2, 3, 5,
  6, 7, 8, 9) with `codesign --timestamp -s "Developer ID Application: <Org>
  (<TEAMID>)" --options runtime <bundle>.vst3` for all seven build outputs
  (`loopy_vst3_delay`, `_reverb`, `_echo`, `_drive`, `_filter`, `_tremolo`,
  `_octaver`). Requires a Developer ID certificate provisioned into CI (or
  documented as a manual local-signing step if CI secrets aren't in scope
  for this part — confirm with the team's existing macOS signing setup, if
  any exists for other artifacts).
- [ ] Add a codesign entitlements plist appropriate for an audio-plugin
  bundle under hardened runtime (shared across all seven — audio plugins
  typically need none of the sandboxing exceptions the main app's
  microphone entitlement needs), applied uniformly.
- [ ] `codesign --verify --deep --strict` all seven bundles as a build-time
  check.
- [ ] Document (README or CI comment) that individual `.vst3` notarization
  is **not** performed standalone in this pipeline — notarization rides the
  part 15 installer submission; note this explicitly as the chosen flow, not
  an oversight.
- [ ] Manual verification: install signed-but-not-yet-installer-packaged
  bundles on a clean macOS VM/account with no prior Gatekeeper exemption,
  confirm none are blocked when Ableton scans them (this specifically tests
  the signature + hardened runtime, independent of part 15's
  installer-level notarization). Spot-check all seven, not just one.

## File References

- `packages/loopy_engine/vst3/CMakeLists.txt` (post-build signing step,
  extended to all seven targets)
- New: entitlements plist for the plugin bundles (shared)
- `packages/loopy_engine/vst3/README.md` (documents the signing flow / cert
  requirements)

## Acceptance Criteria

- [ ] All seven `.vst3` bundles are signed with a Developer ID Application
  certificate, hardened runtime on, timestamped.
- [ ] `codesign --verify --deep --strict` passes for all seven bundles.
- [ ] Manual Gatekeeper check on a clean machine/VM passes for a
  representative sample (at minimum: one 3-param delay-family effect, one
  2-param effect, Octaver) with no unnotarized-scan rejection, distinct from
  the full notarized-installer flow verified in part 15.

## Out of Scope

The app installer itself and its notarization submission (part 15);
Windows/Linux signing (parts 13, 14/17).
