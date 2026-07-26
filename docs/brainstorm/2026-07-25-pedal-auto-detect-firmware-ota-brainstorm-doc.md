---
date: 2026-07-25
topic: pedal-auto-detect-firmware-ota
---

# Console Pedal Auto-Detect + Firmware Updates Shipped With The App

## What We're Building

Two related gaps surfaced while proving out the appliance OTA system (#304/#306) with
a real pedal LED fix (#216):

1. **Auto-detect, not select.** On the console (Raspberry Pi appliance), the Pro Micro
   pedal is a fixed, wired-in component of the unit — not one of several possible MIDI
   devices a user might own. The manual `MidiDevicePicker` dropdown
   ([lib/audio_setup/view/midi_device_picker.dart](../../lib/audio_setup/view/midi_device_picker.dart))
   shouldn't exist there; the app should just find and bind it.
2. **Firmware ships with the app.** #216 (LED gamma fix) was delivered by hand-flashing
   the pedal with `arduino-cli` — entirely outside the appliance's RAUC A/B OTA system.
   When the app updates via that system, the paired pedal firmware should update too, so
   the two versions never drift apart on a shipped release.

## Why This Approach

Two prior brainstorm/plan pairs already cover adjacent ground and must not be
contradicted or duplicated:

- [2026-06-14-midi-usb-device-selection-brainstorm-doc.md](2026-06-14-midi-usb-device-selection-brainstorm-doc.md)
  / [2026-06-14-feat-native-midi-device-selection-plan.md](../plan/2026-06-14-feat-native-midi-device-selection-plan.md)
  — built the generic native MIDI enumerate/select/persist path. Still fully manual;
  no auto-select concept was ever added.
- [2026-06-14-looper-pedal-firmware-protocol-brainstorm-doc.md](2026-06-14-looper-pedal-firmware-protocol-brainstorm-doc.md)
  / [2026-06-14-feat-looper-pedal-protocol-firmware-plan.md](../plan/2026-06-14-feat-looper-pedal-protocol-firmware-plan.md)
  — **already designed a SysEx identity handshake** for pedal auto-detection
  (`PedalCodec.encodeIdentityRequest()`, the Universal Non-Real-Time Identity Request
  `F0 7E 7F 06 01 F7`, manufacturer id `0x7D`) and it is **already implemented**:
  `PedalRepository.bind()` broadcasts it and verifies the reply. **What's missing is not
  the handshake — it's that the handshake only ever runs over the single MIDI port the
  user already picked by hand** (`NativePedalTransport`'s `input` is injected from the
  one capture `MidiSetupCubit` opens). There is no VID/PID matching anywhere in the app
  or its native MIDI backends (CoreMIDI/ALSA/WinMM) — the identity handshake was always
  meant to be the sole detection mechanism, per the original design.

This means **auto-detect on console is much smaller than it first looked**: no new
native FFI work, no VID/PID plumbing — reuse the existing handshake, just drive it from
an auto-selecting caller instead of a human-driven dropdown, gated on the existing
`kConsoleMode` flag ([lib/common/console_mode.dart](../../lib/common/console_mode.dart)),
the established pattern for console-only behavior branches.

**Firmware-ships-with-the-app is genuinely new work.** Nothing in the repo packages,
versions, or flashes pedal firmware today — it's 100% manual `arduino-cli` per
[hardware/firmware/loopy_pedal_32u4/README.md](../../hardware/firmware/loopy_pedal_32u4/README.md).
The appliance OTA system built this session (#304/#306, PR1-PR3b, merged) already has
the shape this needs: a channel manifest, a signed/verified download, a privileged
on-device helper (`loopy-update-ctl`) driving a PROGRESS-line protocol the Dart layer
consumes. The natural move is to extend that shape to cover a second artifact (a
firmware `.hex`) rather than invent a parallel system.

## Key Decisions

- **Auto-detect stays Dart-only, reusing the existing identity handshake.** No native
  backend changes. On `kConsoleMode`, skip the manual picker; enumerate MIDI inputs and
  bind via `PedalRepository.bind()`'s handshake — trying the sole enumerated device in
  the common case, and disambiguating by handshake reply if more than one port exists.
  *Rationale:* the design for this already exists and works; the only change is who
  drives it.

- **Firmware version becomes real, and rides the semver work already in flight (#329).**
  Today there is no firmware version at all — only a protocol version
  (`PEDAL_PROTOCOL_VERSION`). Add a firmware build version reported over the identity
  reply, and carry it in the same channel manifest the app version now uses semver for.
  *Rationale:* one version scheme, one manifest, one place a device checks "am I current."

- **Firmware download/flash follows the `loopy-update-ctl` shape, not a new system.**
  Extend the channel manifest with a sibling `pedalFirmware: {version, hex, sha256}`
  entry (the `.hex` is not part of the RAUC bundle — it targets USB-attached MCU
  flash, not the OS image), and add a new verb to the on-device privileged helper that
  downloads/verifies/flashes it, using the same PROGRESS-line protocol the UI already
  parses. *Rationale:* reuse a proven, already-tested pattern rather than design a
  second one.

- **Flashing mechanism: `avrdude` + a Caterina touch-reset, from a new privileged
  helper verb.** The 32U4/Leonardo bootloader is entered by a 1200bps open/close on the
  CDC port — `arduino-cli upload` does this automatically today; the appliance needs
  the equivalent sequence itself, then hands off to `avrdude` (new RDEPENDS on the
  Yocto image, alongside the existing `rauc`/`curl`/`jq`).

- **Fix the protocol-version drift before building on top of it.** `firmware/loopy_pedal/pedal_protocol.h`
  is on `PEDAL_PROTOCOL_VERSION_V2`; `hardware/firmware/loopy_pedal_32u4/pedal_protocol.h`
  — the copy that's actually flashed to the shipping board — is still hardcoded to
  `V1`. The 32U4 README documents a manual `diff` sync check; nothing enforces it in
  CI, and it has silently drifted. *Rationale:* shipping an OTA'd firmware built from a
  stale protocol copy would regress features (`looper_mode`/`counting_in`) that #289
  already added to the canonical copy.

- **Desktop is out of scope.** The auto-detect ask is explicitly "if it's a console";
  desktop keeps the manual dropdown (users may have arbitrary MIDI gear). No
  firmware-push path is planned for desktop-attached pedals in this pass.

## Open Questions (for the planning phase)

- **Multi-device disambiguation.** How many MIDI inputs can realistically be enumerated
  on a sealed console appliance, and does the auto-bind path need to *sequentially*
  open+probe each one (only one native capture exists at a time today per
  `NativePedalTransport`'s design), or is "bind the first, and only fall back if the
  handshake never replies" sufficient for v1?
- **Firmware manifest shape.** Nest `pedalFirmware` inside the existing
  `UpdateManifest`/manifest.json, or a wholly separate manifest URL? The former keeps
  "one fetch, one place to look"; the latter decouples pedal-firmware cadence from
  app-release cadence if they ever need to move independently.
- **Flash trigger point.** Alongside `applyAndRestart()` (same moment as the app
  reboot), or as its own separate confirm step in Settings? The ask is "updates along
  with the app," which argues for bundling into the same user-facing action.
- **Failure/rollback story.** RAUC has A/B safety for the OS; the pedal has no
  equivalent — a failed/interrupted flash mid-write can brick the MCU until a bootloader
  recovery. Needs a real answer (verify-after-write? refuse to flash if pedal isn't in
  a known-good bind state first?) before this ships.
- **CI enforcement of the protocol-version sync.** Extend the existing host contract
  test ([.github/workflows/main.yaml:133-141](../../.github/workflows/main.yaml)) to
  diff-check both `pedal_protocol.h` copies, or move to a single generated/symlinked
  source so they structurally can't drift again?
