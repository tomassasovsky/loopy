---
title: "feat(app): macOS app installer, all seven plugins (part 15)"
type: feat
date: 2026-07-08
part: 15 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 15 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-DIST, D-UNINSTALL) lives in the umbrella.
> Formerly part 10 (Delay + Reverb only) — **scope widened** to all seven
> plugin bundles. This is the **first macOS app installer Loopy has ever
> had** — no `.pkg`/`.dmg` infrastructure exists in this repo today. Scoped
> deliberately larger than a typical part given that.

## Dependencies

Part 12 (all seven plugin bundles must be Developer ID signed before
packaging).

## Overview

Builds a notarized macOS installer (`.pkg`, chosen over a plain `.dmg`
drag-install since a `.pkg` can run a payload script to place files into the
system VST3 folder — a `.dmg` cannot script post-copy actions) that installs
the Loopy app **and** all seven signed `.vst3` bundles into
`~/Library/Audio/Plug-Ins/VST3` (or `/Library/Audio/Plug-Ins/VST3` if a
system-wide install is chosen — decide at implementation time based on
whether the app installer itself is per-user or system-wide). Per research,
routing the plugins through this notarized installer means the `.vst3`
bundles don't need individual `stapler staple` — the installer's own
notarization ticket covers what's unpacked from it, as long as each payload
item is already signed (part 12).

Per umbrella D-UNINSTALL: if an uninstaller is built as part of this
packaging effort, it must **not** remove any of the seven plugin bundles —
they stay installed independent of the app's own lifecycle.

## Tasks

- [ ] Choose and scaffold a macOS packaging toolchain (e.g. `pkgbuild`/
  `productbuild`, or an existing Flutter-macOS-distribution tool if the team
  has a preference) — this repo has no precedent to follow, so document the
  choice and rationale in a new `packaging/macos/README.md`.
- [ ] Package script: builds the Loopy `.app` (release build), stages all
  seven signed `.vst3` bundles (from part 12) as payload alongside it.
- [ ] Installer payload places the app in `/Applications` and all seven
  `.vst3` bundles into the chosen standard VST3 folder — decide + document
  per-user vs. system-wide.
- [ ] Sign the `.pkg` itself with a separate Developer ID Installer
  certificate (distinct cert type from the Developer ID Application cert
  used for the app/plugins).
- [ ] `notarytool submit` the `.pkg`; `stapler staple` the `.pkg` itself
  (not the individual plugin bundles, per the researched flow).
- [ ] If an uninstaller/uninstall path exists (or is added), explicitly
  exclude the VST3 folder from anything it removes (D-UNINSTALL) —
  document this as a deliberate decision in the uninstaller's own comments,
  not a gap.
- [ ] Manual verification on a clean macOS VM/account: install via the
  `.pkg`, confirm the app launches, confirm all seven `.vst3` bundles appear
  in the standard folder and load correctly in Ableton, confirm no
  Gatekeeper warning at any step; uninstall (or manually remove) the app and
  confirm the plugin bundles remain and a previously-exported `.als`
  referencing them still opens correctly in Ableton.

## File References

- New: `packaging/macos/` (installer build scripts, `README.md`)
- `packages/loopy_engine/vst3/{delay,reverb,echo,drive,filter,tremolo,octaver}/`
  (signed payload, part 12)
- CI workflow additions (`.github/workflows/`) if the installer build is
  wired into CI/release automation.

## Acceptance Criteria

- [ ] A `.pkg` builds successfully from a release build of the app plus all
  seven signed plugin bundles.
- [ ] `notarytool submit` returns `Accepted`; the `.pkg` is stapled.
- [ ] Clean-VM manual install check (above) passes in full, including the
  post-uninstall plugin-persistence check (D-UNINSTALL) for all seven
  bundles.

## Out of Scope

Windows (part 16), Linux (part 17) installers; any change to the plugins
themselves (parts 2/3/5-9/12 already finalized their signed artifacts).
