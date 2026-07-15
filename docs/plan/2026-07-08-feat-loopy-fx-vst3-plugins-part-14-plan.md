---
title: "feat(vst3): Linux plugin port, all seven plugins (part 14)"
type: feat
date: 2026-07-08
part: 14 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 14 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-VALIDATE) lives in the umbrella. Formerly part 9
> (Delay + Reverb only) — **scope widened** to all seven plugins. Ports
> parts 2/3/5-9's plugin source to Linux; **no code signing** (D-SIGN: not a
> VST3 distribution convention on Linux).

## Dependencies

Part 1 (portable `loopy_dsp_core`), parts 2, 3, 5, 6, 7, 8, 9 (all seven
plugins' source to port).

## Overview

Same C++ source as parts 2/3/5-9 and part 13 — this part is Linux CMake
wiring (GCC/Clang) plus the Linux `.vst3` bundle layout and standard install
location, applied to all seven targets. Per research, Steinberg's documented
priority order is `$HOME/.vst3/` (per-user, no elevated perms) above
`/usr/lib/vst3/` (system-wide); this part's **local dev-install**
verification targets `~/.vst3` (no elevated perms needed for dev
iteration), while the **packaged** install location (`/usr/lib/vst3`,
matching `.deb` convention) is decided in part 17.

**Verification substitute (D-VALIDATE):** Ableton Live has no native Linux
build, so the manual real-DAW check for this part uses **REAPER or Bitwig**
instead — an explicit, documented substitution, not a gap. This also means a
Linux user exporting from Loopy cannot locally preview a real-plugin export
through Ableton itself.

## Tasks

- [ ] Extend `packages/loopy_engine/vst3/CMakeLists.txt` with a Linux
  branch covering all seven targets: GCC/Clang flags matching the rest of
  the engine's existing Linux build configuration.
- [ ] Linux `.vst3` bundle layout (`<Name>.vst3/Contents/x86_64-linux/<Name>.so`
  + `Contents/Resources/`) as a shared CMake helper reused by all seven
  targets.
- [ ] Local dev-install verification: copy all seven built bundles to
  `~/.vst3/`.
- [ ] Manual verification (D-VALIDATE): insert all seven plugins into
  REAPER or Bitwig on Linux; same checklist as parts 2/3/5-9/13 (param
  list/ranges, audio, automation, mono-input stereo-tail check for Reverb,
  latency-compensation check for Octaver if applicable). Record which host
  was used, since "many plugins ship no Linux build" is a known ecosystem
  gap worth confirming this plan doesn't hit for any of its seven plugins.
- [ ] No signing step (D-SIGN) — document this explicitly in
  `packages/loopy_engine/vst3/README.md` as a deliberate decision, not an
  oversight, citing the researched industry norm (trust rides the package
  manager for `.deb`, not per-binary signing).

## File References

- `packages/loopy_engine/vst3/CMakeLists.txt` (Linux branch, covering all
  seven targets)
- `packages/loopy_engine/vst3/{delay,reverb,echo,drive,filter,tremolo,octaver}/`
  (source, unchanged from their respective parts)
- `packages/loopy_engine/vst3/README.md` (Linux build instructions +
  no-signing rationale, extended)

## Acceptance Criteria

- [ ] All seven plugin targets build a valid Linux `.vst3` bundle via
  GCC/Clang.
- [ ] Manual REAPER-or-Bitwig load check passes for all seven plugins.
- [ ] `packages/loopy_engine/vst3/README.md` documents the no-signing
  decision and which host was used for the manual check.

## Out of Scope

Linux app packaging / `/usr/lib/vst3` system install (part 17 — this part
is plugin build + local dev-install only).
