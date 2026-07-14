---
title: "feat(app): Linux app packaging, all seven plugins (part 17)"
type: feat
date: 2026-07-08
part: 17 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 17 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-DIST, D-UNINSTALL) lives in the umbrella.
> Formerly part 12 (Delay + Reverb only) — **scope widened** to all seven
> plugin bundles. This is the **first Linux package Loopy has ever had** —
> no `.deb`/`.rpm` infrastructure exists in this repo today.

## Dependencies

Part 14 (all seven plugin bundles must build for Linux before packaging).

## Overview

Builds a `.deb` package (chosen over `.rpm`/generic installer as the more
standard target for this repo's likely distro — confirm at implementation
time whether an `.rpm` is also wanted) that installs the Loopy app **and**
all seven `.vst3` bundles into `/usr/lib/vst3` (system-wide, matching
Steinberg's documented priority order and how most Linux-packaged plugin
suites operate) via the package's own file manifest — no custom postinst
placement logic needed, matching research findings that this is the
conventional `.deb` approach.

Per umbrella D-UNINSTALL: `apt remove`/`dpkg -r` on the Loopy package should
**not** remove any of the seven `/usr/lib/vst3/Loopy <Name>.vst3` bundles —
since `.deb`'s default behavior removes exactly what its file manifest
lists, achieving D-UNINSTALL here means **not** listing the plugin files as
owned by the Loopy package's own removal set (e.g. a `postinst`/`prerm`
exception, or packaging the plugins as a separate, independently-tracked
file group). This needs explicit design at implementation time — the
default `.deb` behavior does the opposite of D-UNINSTALL unless deliberately
overridden.

## Tasks

- [ ] Scaffold `.deb` packaging (`debian/control`, `debian/rules`, or a
  tool like `fpm`/`cpack`) — document the choice in a new
  `packaging/linux/README.md`, since this repo has no precedent.
- [ ] Package file manifest: the Loopy app binary/assets, plus all seven
  `.vst3` bundles (part 14) targeting `/usr/lib/vst3/`.
- [ ] Design and implement the D-UNINSTALL exception explicitly (see
  Overview) — verify via a real `dpkg -r` on a test install that all seven
  plugin file trees survive.
- [ ] No code-signing step (D-SIGN, reaffirmed from part 14) — GPG-sign the
  `.deb`/repository metadata only if this repo already has (or is adding) an
  apt-repository publishing flow; otherwise document as out of scope for
  this part.
- [ ] Manual verification on a clean Linux VM/container: install the `.deb`,
  confirm the app launches, confirm all seven plugins appear in
  `/usr/lib/vst3` and load in REAPER or Bitwig (per part 14's chosen
  verification host), remove the package, confirm the plugin files remain
  and a previously-exported `.als` (opened in REAPER/Bitwig, since Ableton
  has no Linux build) still resolves them correctly.

## File References

- New: `packaging/linux/` (packaging scripts, `README.md`)
- `packages/loopy_engine/vst3/{delay,reverb,echo,drive,filter,tremolo,octaver}/`
  (built payload, part 14)
- CI workflow additions if the package build is wired into CI/release
  automation.

## Acceptance Criteria

- [ ] The `.deb` builds successfully from a release build of the app plus
  all seven built plugin bundles.
- [ ] Clean-VM/container manual install check (above) passes in full,
  including the post-removal plugin-persistence check (D-UNINSTALL) for all
  seven bundles.
- [ ] `packaging/linux/README.md` documents the D-UNINSTALL exception
  mechanism used and why the default `.deb` removal behavior needed
  overriding.

## Out of Scope

macOS (part 15), Windows (part 16) installers; `.rpm` or other Linux package
formats beyond `.deb` (revisit if a real need surfaces); code signing
(D-SIGN — not a Linux VST3 convention).
