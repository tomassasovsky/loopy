---
title: "feat(app): Windows app installer, all seven plugins (part 16)"
type: feat
date: 2026-07-08
part: 16 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 16 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-DIST, D-UNINSTALL) lives in the umbrella.
> Formerly part 11 (Delay + Reverb only) — **scope widened** to all seven
> plugin bundles. This is the **first Windows app installer Loopy has ever
> had** — no `.msi`/`.exe` installer infrastructure exists in this repo
> today.

## Dependencies

Part 13 (all seven plugin bundles must be Authenticode-signed before
packaging).

## Overview

Builds a signed Windows installer (WiX Toolset, Inno Setup, or NSIS — pick
one; WiX is the most common choice for `%COMMONPROGRAMFILES%`-targeting
installers per research) that installs the Loopy app **and** all seven
signed `.vst3` bundles into `%COMMONPROGRAMFILES%\VST3`
(`C:\Program Files\Common Files\VST3`) — the standard system-wide location,
which requires the installer to run elevated (UAC prompt), matching
conventional VST3 installer behavior.

Per umbrella D-UNINSTALL: the generated uninstaller must **not** remove any
of the seven plugin bundles from `%COMMONPROGRAMFILES%\VST3`.

## Tasks

- [ ] Choose and scaffold a Windows installer toolchain (WiX/Inno/NSIS) —
  document the choice and rationale in a new `packaging/windows/README.md`,
  since this repo has no precedent.
- [ ] Installer script: stages the Loopy release build + all seven signed
  `.vst3` bundles (part 13) as payload; requests elevation
  (`RequireAdministrator`/equivalent) since `%COMMONPROGRAMFILES%` is a
  protected path.
- [ ] Installer places the app in the standard Program Files location and
  all seven `.vst3` bundles into `%COMMONPROGRAMFILES%\VST3`.
- [ ] Sign the installer executable itself (Authenticode + timestamp, same
  convention as part 13's per-binary signing).
- [ ] The generated uninstaller explicitly excludes all seven
  `%COMMONPROGRAMFILES%\VST3\Loopy <Name>.vst3` bundles from removal
  (D-UNINSTALL) — document as deliberate in the installer script's
  comments.
- [ ] Manual verification on a clean Windows VM: run the installer, confirm
  UAC elevation prompt appears, confirm the app launches, confirm all seven
  plugins appear in `%COMMONPROGRAMFILES%\VST3` and load in Ableton for
  Windows, confirm no SmartScreen warning. Uninstall and confirm the
  plugins remain and a previously-exported `.als` still opens correctly.

## File References

- New: `packaging/windows/` (installer script, `README.md`)
- `packages/loopy_engine/vst3/{delay,reverb,echo,drive,filter,tremolo,octaver}/`
  (signed payload, part 13)
- CI workflow additions if the installer build is wired into CI/release
  automation.

## Acceptance Criteria

- [ ] The installer builds successfully from a release build of the app
  plus all seven signed plugin bundles.
- [ ] The installer executable is Authenticode-signed and timestamped;
  `signtool verify /pa` passes.
- [ ] Clean-VM manual install check (above) passes in full, including the
  post-uninstall plugin-persistence check (D-UNINSTALL) for all seven
  bundles and no SmartScreen warning.

## Out of Scope

macOS (part 15), Linux (part 17) installers; any change to the plugins
themselves (parts 2/3/5-9/13 already finalized their signed artifacts).
