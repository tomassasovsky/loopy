---
title: "feat: console pedal auto-detect + firmware updates shipped with the app"
type: feat
date: 2026-07-25
---

## feat: console pedal auto-detect + firmware updates shipped with the app

> **SUPERSEDED (2026-08-01)** by
> [docs/plan/2026-08-01-feat-pedal-auto-detect-firmware-ota-plan.md](2026-08-01-feat-pedal-auto-detect-firmware-ota-plan.md).
> The prerequisite (protocol drift + CI gate) shipped independently, and this plan's
> auto-detect and firmware-version mechanisms both assume a SysEx identity *reply* that
> loopy's 3-byte native capture cannot deliver. Kept for history; do not build from it.

> Source brainstorm: [docs/brainstorm/2026-07-25-pedal-auto-detect-firmware-ota-brainstorm-doc.md](../brainstorm/2026-07-25-pedal-auto-detect-firmware-ota-brainstorm-doc.md).
> Builds on the appliance A/B update system (#304/#306, merged) and the pedal
> identity-handshake protocol (#149, merged). Tracking issue: #331.

## Overview

Two changes to the console (Raspberry Pi appliance) build: (1) the Pro Micro pedal is
auto-detected via the identity handshake that already exists, instead of requiring
manual MIDI device selection; (2) pedal firmware becomes a versioned, OTA-delivered
artifact that travels with app updates, instead of a hand-run `arduino-cli upload`.

## Problem Statement

- `MidiDevicePicker` requires a human to pick a device from a dropdown. On a sealed
  console with one wired-in MIDI device, this is pure friction — worse, it's a UI
  surface that shouldn't exist on that build at all.
- The pedal LED fix (#216) was delivered by physically connecting a laptop and running
  `arduino-cli upload`. The appliance's own OTA system (proven end-to-end this session)
  has no concept of pedal firmware, so every future firmware fix repeats that manual
  process indefinitely, and the shipped app version and shipped firmware version have
  no guaranteed relationship.
- `hardware/firmware/loopy_pedal_32u4/pedal_protocol.h` has already drifted from the
  canonical `firmware/loopy_pedal/pedal_protocol.h` (stuck on `PEDAL_PROTOCOL_VERSION_V1`
  vs. the canonical `V2`), undetected by CI. Building an OTA path on top of a stale,
  unenforced copy would ship that drift as the new "latest."

## Proposed Solution

```
                    ┌─ Console-only (kConsoleMode) ─────────────────┐
                    │  MidiSetupCubit auto-binds the sole/matching  │
                    │  MIDI input via PedalRepository's EXISTING    │
                    │  identity handshake — no picker UI.           │
                    └────────────────────────────────────────────────┘

CI (new, light job)                    CI (existing appliance-release.yml)
  arduino-cli compile                    build-app (Flutter bundle)
  loopy_pedal_32u4 → .hex                build-image (Yocto/RAUC .raucb)
  version = VERSION file (#329)                  │
       │                                          ▼
       └──────────────► manifest.json { version, bundle, sha256,
                                          pedalFirmware: { version, hex, sha256 } }
                                          │
                                          ▼ segno.aquiles.dev mirror
                                          │
                                Pi appliance: loopy-update-ctl
                                  install   → RAUC A/B (existing)
                                  flash-pedal (NEW) → touch-reset + avrdude
```

### Prerequisite: fix the protocol drift

Before anything else, sync `hardware/firmware/loopy_pedal_32u4/pedal_protocol.h` /
`.c` to the canonical `V2` copy (bring in `looper_mode`/`counting_in` from #289), and
add a CI check — extend the existing host contract test
([.github/workflows/main.yaml:133-141](../../.github/workflows/main.yaml)) to also
build/link against the 32U4 copy and diff the two headers, so this can't silently
recur. Small, narrow, mechanical — ships as its own PR ahead of the rest.

### Part A — Console auto-detect (small, Dart-only)

- `MidiDeviceRepository`/`MidiSetupCubit` gain a console-only auto-bind path: on
  `kConsoleMode`, skip persisted-selection UI entirely; enumerate MIDI inputs and, for
  each, attempt `PedalRepository.bind()`'s existing identity handshake
  (`encodeIdentityRequest`), binding the first that replies with the pedal's known
  signature. With exactly one device present (the normal case) this resolves
  immediately without a second round-trip.
- `pedal_settings_section.dart` on console shows bind status only (bound / searching /
  not found) — no device chooser control. Desktop is unchanged: manual dropdown stays.
- No native/FFI change. No VID/PID work. Reuses `PedalCodec`/`PedalRepository` exactly
  as built for #149.

### Part B — Firmware version + identity reply

- Add a real firmware build version, sourced the same way the app's `VERSION` file
  works (#329) — either a sibling `firmware/loopy_pedal/VERSION` or reuse the repo-root
  one, TBD in review. Report it in the identity handshake reply so the app can read
  "what firmware is currently on the pedal" without a separate query.
- This likely needs a small, additive protocol bump (a new field on the identity reply
  payload, not the state-frame `PEDAL_MSG_TYPE_STATE`) — scope precisely during
  plan-review against the current `pedal_codec.dart` identity-reply decode.

### Part C — CI: build + publish the firmware artifact

- New lightweight job (does **not** need the self-hosted/Yocto runner — `arduino-cli`
  compile is fast) in `appliance-release.yml` or a sibling workflow: `arduino-cli
  compile` for `hardware/firmware/loopy_pedal_32u4` with the documented build
  properties (`arduino:avr:leonardo`, `build.pid=0x7D00`,
  `build.usb_product="VAMP Loopstation"`), stamping the version from Part B.
- Upload the `.hex` as a release artifact alongside the `.raucb`, and extend
  `manifest.json` with the `pedalFirmware: {version, hex, sha256}` block from the
  brainstorm doc.

### Part D — On-device flashing helper

- Add `avrdude` to `loopy-bundle.bb`'s `RDEPENDS` (next to the existing `rauc`/`curl`/`jq`).
- New verb on `loopy-update-ctl` (or a sibling helper, matching its shape exactly:
  `set -eu`, `PROGRESS <0-100>` lines on stdout, `log()` to stderr): `flash-pedal`.
  Performs the Caterina 1200bps touch-reset on the pedal's CDC port, then `avrdude -p
  atmega32u4 -c avr109 ...` against the freshly-appeared bootloader port, verifying the
  write.
- **Safety:** refuse to flash unless the pedal is currently bound (known-good identity
  handshake) immediately beforehand; verify-after-write before declaring success;
  surface a clear failure state in the UI rather than silently leaving the pedal
  unresponsive (full recovery story is an open question — see brainstorm doc — resolve
  in plan-review before Part D starts).

### Part E — Wire it into the existing update flow

- Extend `UpdateManifest` (already migrating to semver on #329) with the optional
  `pedalFirmware` field; `UpdateCubit`/`updates_settings_section.dart` surface it as
  part of the same available/downloading/staged flow already built (PR1-PR3b), so
  "update available" and "restart to apply" cover both artifacts as one user action —
  matching the ask that firmware "updates along with the loopy app."

## PR Breakdown

1. **Fix protocol drift** + CI diff-check (prerequisite, narrow, `autonomy:auto`
   candidate).
2. **Console auto-detect** (Part A) — Dart-only, testable end-to-end here
   (`autonomy:auto`/`merge-gate` candidate).
3. **Firmware version + identity-reply field** (Part B) — small protocol addition.
4. **CI firmware build + manifest extension** (Part C).
5. **On-device flashing helper + Yocto packaging** (Part D) — `autonomy:blocked-verify`,
   real hardware flashing cannot be proven safe from CI alone.
6. **Update-flow wiring** (Part E) — depends on 3 and 4.

## Alternative Approaches Considered

- **VID/PID matching in the native MIDI backends** — rejected; the identity handshake
  already does this job at the protocol layer and is already implemented, so adding a
  second, redundant identification mechanism (that also wouldn't be portable — MIDI
  APIs don't uniformly expose USB VID/PID) would be pure duplication.
- **A wholly separate pedal-firmware update system/server** — rejected; the appliance
  OTA system's manifest/download/verify/PROGRESS-line shape already solves this
  problem for the OS bundle. Reusing it is less code and one mental model for "how does
  this appliance update."
- **Embed the `.hex` inside the RAUC bundle itself** — rejected; RAUC bundles are for
  the OS image (A/B slots); the pedal firmware targets a USB-attached MCU with an
  entirely different flashing mechanism (avrdude, not RAUC), so it doesn't belong in
  the same artifact.

## Open Questions Carried Into Plan-Review

See the brainstorm doc's Open Questions — multi-device disambiguation depth, manifest
nesting vs. separate URL, flash trigger point (bundled vs. standalone), and the
flash-failure/recovery story all need a direction call before Part D/E start.
