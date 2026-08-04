---
title: "feat: console pedal auto-detect + firmware updates shipped with the app (revised)"
type: feat
date: 2026-08-01
---

## feat: console pedal auto-detect + firmware updates shipped with the app (revised)

> **Supersedes** [docs/plan/2026-07-25-feat-pedal-auto-detect-firmware-ota-plan.md](2026-07-25-feat-pedal-auto-detect-firmware-ota-plan.md).
> Source brainstorm: [docs/brainstorm/2026-07-25-pedal-auto-detect-firmware-ota-brainstorm-doc.md](../brainstorm/2026-07-25-pedal-auto-detect-firmware-ota-brainstorm-doc.md).
> Tracking issue: #331 (`epic`, `stage:plan`, `autonomy:plan-gate`).

## Why this plan was rewritten

The 2026-07-25 plan was written before the FX v3 / protocol-v3 work landed. Three of
its load-bearing statements are no longer true, and one of its two mechanisms is
impossible as specified. Re-verified against the tree at `872cd17d`:

| 2026-07-25 plan said | Reality at `872cd17d` |
| --- | --- |
| Prerequisite: `hardware/firmware/segno_pedal_32u4/pedal_protocol.h` has drifted to V1; add a CI diff-check | **Already done.** Both copies are byte-identical at `PEDAL_PROTOCOL_VERSION_V3`, and [firmware/test/run_tests.sh:20-26](../../firmware/test/run_tests.sh) is the enforced drift gate (wired into the repo's required verify loop). |
| Part A: auto-bind by "attempting `PedalRepository.bind()`'s existing identity handshake, binding the first that **replies**" | **Impossible.** The identity request goes *out*, but no reply can come *back*: the native capture delivers 3-byte Note/CC only and drops SysEx ([pedal_transport.dart:5-10](../../packages/pedal_repository/lib/src/pedal_transport.dart), [pedal_repository.dart:13-16](../../packages/pedal_repository/lib/src/pedal_repository.dart)). There is no reply-based auto-detect to reuse. |
| Part B: report the firmware version "in the identity handshake reply" — "no native/FFI change" | Same blocker. Reading a version *off the pedal* requires a SysEx-capable inbound path in all three native backends — exactly the native work the plan ruled out. |
| Desktop keeps the dropdown; console gets auto-detect | Still true, but **#343 already hid the MIDI/pedal pickers on console.** So today a fresh console has *no* way to bind the pedal at all — it works only if a selection was persisted while the pickers were still visible. Part A went from "remove friction" to "fix a real gap." |

Also new since the old plan: protocol v3 (#398) shipped a **manual** "pedal firmware
version" setting as the interim version-discovery gate, routed through the single seam
`PedalCubit._applyFirmwareVersion` ([pedal_cubit.dart:158-172](../../lib/pedal/cubit/pedal_cubit.dart)),
with `PedalRepository.targetProtocolVersion` holding an unknown ⇒ v2 safety floor. Any
automatic version discovery must feed that same seam, not add a second one.

## Problem Statement

1. **The console cannot bind its own pedal.** The Pro Micro is fixed, wired-in hardware,
   and #343 removed the only UI that could select it. Nothing auto-binds it.
2. **Pedal firmware still ships by hand.** `arduino-cli upload` from a laptop (#216).
   No CI job builds a `.hex`; nothing in `deploy/yocto/**` or `.github/workflows/**`
   mentions pedal firmware; `UpdateManifest` has no firmware field
   ([update_manifest.dart:9-42](../../packages/update_repository/lib/src/update_manifest.dart)).
   App version and firmware version have no guaranteed relationship.
3. **Version discovery is manual.** A user must know and pick their pedal's protocol
   version, or the app permanently encodes at the v2 floor and shows a "firmware update
   available" banner it cannot act on.

## Decisions taken (were open questions)

**D1 — Match rule: name-match only.** Auto-detect binds a MIDI device whose reported
name identifies it as the pedal; it never binds "the only device present."

*Consequence, accepted:* a Pro Micro flashed **before** the `build.usb_product="Segno
Loopstation"` rename enumerates as `Arduino Leonardo` and will never auto-bind — and on
console there is no picker to fall back on. Recovery is to reflash it from a desktop
build. This is the price of predictability: sole-device fallback would bind *any* stray
USB-MIDI device as if it were the pedal.

*Implementation note the rule needs:* the OS-reported name is not equal to the product
string on every platform. ALSA (the console's backend) typically reports
`Segno Loopstation MIDI 1` or `Segno Loopstation:Segno Loopstation MIDI 1 20:0`, not the
bare string. The match must therefore be a **case-insensitive substring** test against
one shared token constant, not string equality — with the token defined once and used by
both the input and output sides.

**D2 — CI enforcement of protocol sync: already answered by the tree.** The diff gate in
`firmware/test/run_tests.sh` exists and works; do not replace it with a symlink/codegen
scheme. This item is closed, not planned.

## Revised scope

### Part A — Console auto-detect (Dart-only, verifiable here)

Two *independent* bindings must both resolve on console, and the old plan only named one:

- **MIDI input** — `MidiDeviceRepository`, pinned by the persisted selection, reconciled
  in `_hydrate()` ([:89](../../packages/midi_device_repository/lib/src/midi_device_repository.dart))
  and `refresh()` ([:187](../../packages/midi_device_repository/lib/src/midi_device_repository.dart)).
- **Pedal output** — `PedalCubit`, pinned by `_savedOutputId`, reconciled in `_restore()`
  and `reconnect()` ([pedal_cubit.dart:57-78, 178-199](../../lib/pedal/cubit/pedal_cubit.dart)).

Both already have the right shape: "resolve a pinned id, bind it when present, re-check
each poll tick." Auto-detect is one new step in front of that — **when console mode is on
and nothing is pinned, derive the pin by name-matching the enumerated devices** — so
hotplug, replug, and retry-after-error keep working unchanged for free.

- No new UI. `pedal_settings_section.dart` stays hidden on console (#343); bind status is
  already surfaced by existing state.
- Desktop is untouched: no console mode ⇒ no auto-pin ⇒ manual dropdown exactly as today.
- No native/FFI change, and — unlike the old Part A — no dependency on an identity reply.

**Tests:** repository/cubit unit tests for match-hit, match-miss (nothing bound, no
crash), substring/case variants (`Segno Loopstation MIDI 1`), two matching devices (bind
first deterministically), console-off (no auto-pin), and auto-pin not clobbering an
existing user selection.

### Part B — Firmware version discovery (rescoped; needs a direction call, see O1)

The old Part B (version in the identity reply) is **blocked** on native SysEx inbound
support. Two ways forward, and they are not equal in cost:

- **B1 — grow the inbound path to carry SysEx.** Touches all three native backends
  (CoreMIDI / ALSA / Windows) plus `PedalTransport`'s `PedalRawMessage` record type,
  which is 3-byte by construction. True "ask the pedal what it runs," works on desktop
  too. Large, native, hardware-verified.
- **B2 — record what was flashed, appliance-side.** The console flasher (Part D) is the
  only thing that ever writes firmware to that pedal, so it already knows the version.
  Write it to `/etc/segno/pedal-firmware-version`, mirroring the existing
  `/etc/segno/build-version` convention ([segno-update-ctl:19-25](../../deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-update-ctl)),
  and have the app read it into the existing `_applyFirmwareVersion` seam. No native
  work; console-only; degrades to the current manual setting on desktop.

**Recommendation: B2 now, B1 only if desktop ever needs automatic discovery.** B2 answers
the actual console question ("what did *we* put on it?") without a three-backend native
change, and it feeds the seam v3 already built.

### Part C — CI: build + publish the firmware artifact

Unchanged from the old plan and still accurate — no `arduino` reference exists in
`.github/workflows/**` today.

- New light job (no self-hosted runner needed): `arduino-cli compile` for
  `hardware/firmware/segno_pedal_32u4` with the documented build properties
  (`arduino:avr:leonardo`, `build.pid=0x7D00`, `build.usb_product="Segno Loopstation"`).
- Version stamped from the repo-root `VERSION` file (it exists; no sibling firmware
  VERSION file needed — one release version covering app + firmware is what "ships with
  the app" means).
- Publish the `.hex` alongside the `.raucb` and extend `manifest.json` with
  `pedalFirmware: {version, hex, sha256}`.

### Part D — On-device flashing helper (`autonomy:blocked-verify`)

Unchanged in shape from the old plan: `avrdude` into `segno-bundle.bb` `RDEPENDS`
([:59](../../deploy/yocto/meta-segno/recipes-segno/segno-bundle/segno-bundle.bb)), a
`flash-pedal` verb matching `segno-update-ctl`'s exact shape (`set -eu`, `PROGRESS <0-100>`
on stdout, `log()` to stderr), 1200bps Caterina touch-reset then `avrdude -p atmega32u4
-c avr109`. Under B2 it also writes `/etc/segno/pedal-firmware-version` on success.

**This part cannot be proven from CI** — it is the one piece that must be validated on
real hardware. See O2 for the safety story it still needs.

### Part E — Wire into the existing update flow

Unchanged: optional `pedalFirmware` on `UpdateManifest`; `UpdateCubit` /
`updates_settings_section.dart` fold it into the existing available/downloading/staged
flow. Depends on C and D.

## PR breakdown

| # | Scope | Depends on | Autonomy | Verifiable here |
| --- | --- | --- | --- | --- |
| ~~0~~ | ~~Protocol drift + CI gate~~ | — | — | **Already shipped — drop** |
| 1 | Part A console auto-detect (name-match, both bindings) | — | `merge-gate` | Yes |
| 2 | Part C CI firmware build + `pedalFirmware` manifest field | — | `merge-gate` | Yes (CI) |
| 3 | Part D `flash-pedal` verb + `avrdude` packaging | 2 | `blocked-verify` | **No** |
| 4 | Part B2 version file read → `_applyFirmwareVersion` | 3 | `merge-gate` | Partly |
| 5 | Part E update-flow wiring | 2, 3 | `merge-gate` | Yes |

PR 1 is independent of the whole firmware-OTA half and is the only piece that fixes a
gap users hit today. It should ship first and alone.

## Open decisions still needing a direction call

- **O1 — Version discovery: B2 (recommended) or B1?** Picking B1 turns a one-PR item into
  a three-backend native change and moves PR 4 ahead of PR 3.
- **O2 — Flash-failure / recovery story.** RAUC gives the OS A/B safety; the pedal has
  none, and a failed mid-write can leave the MCU in its bootloader until someone reflashes
  it over USB. Minimum bar proposed: refuse to flash unless the pedal is bound
  immediately beforehand; `avrdude` verify-after-write; on failure surface an explicit
  "pedal firmware update failed — pedal may need reflashing from a computer" state rather
  than silent breakage. **Needs sign-off before PR 3 starts** — it is the difference
  between a recoverable failure and a bricked unit in a sealed enclosure.
- **O3 — Flash trigger point.** Bundle into the same `applyAndRestart()` action as the OS
  update (matches the "updates along with the app" ask), or a separate confirm step.
  Recommend bundling, gated on O2's safety bar holding.
- **O4 — Manifest nesting.** Keep `pedalFirmware` nested in the existing manifest
  (one fetch, one place to look) vs. a separate manifest URL (independent cadence).
  Recommend nesting; the whole premise is that the two versions move together.

## Alternatives considered (carried forward, still rejected)

- **VID/PID matching in the native backends** — MIDI APIs don't uniformly expose USB
  VID/PID, and D1's name match reaches the same devices with no native code.
- **A separate pedal-firmware update system** — the appliance OTA manifest /
  download / verify / PROGRESS-line shape already solves this; reusing it is less code
  and one mental model.
- **Embedding the `.hex` in the RAUC bundle** — RAUC bundles are OS A/B slot images; the
  pedal is a USB-attached MCU flashed by avrdude. Different artifact, different mechanism.
