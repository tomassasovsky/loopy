---
date: 2026-06-11
topic: windows-linux-native
---

# Windows & Linux Native Implementation

## What We're Building

Bring Loopy to Windows and Linux at the highest feature parity each OS physically
allows. The audio engine C core (`packages/loopy_engine/src/`) is already portable
via vendored **miniaudio** — there are no macOS `#ifdef`s in the DSP, looping,
lock-free ring, or atomic-state code. The work is therefore three things:
(1) get both platforms **building and running end-to-end** (record / loop / play /
per-input monitor / FX) on real hardware; (2) **verify the portable loopback
features** — device-name classification (`le_classify_capture_device`) and the
audio-level round-trip latency-measurement harness — on each OS; and (3) chase the
one genuinely native, macOS-only feature — **per-channel "loopback"-label
exclusion** (`le_compute_excluded_input_mask`, currently a `return 0` stub off
macOS) — as far as each platform's audio APIs permit.

The honest finding driving this doc: full per-channel-label parity is **not
uniformly achievable**. macOS reads arbitrary per-channel name strings via
CoreAudio (`kAudioObjectPropertyElementName`). Windows can only get equivalents via
**ASIO** (`ASIOGetChannelInfo().name`), and Linux's audio stacks expose **no**
arbitrary per-channel labels at all. We pursue every avenue that physically exists,
and document the rest as an OS limitation rather than a TODO.

## Why This Approach

The decisive constraint is what each OS exposes, not engineering effort. Two
research passes established:

- **Windows.** WASAPI / Core Audio DeviceTopology cannot return per-channel name
  strings — `KSJACK_DESCRIPTION` has no name field; pro interfaces present as
  positional channels (~95% confidence dead end). The **only** path to a channel
  label like "Loopback L/R" is **ASIO** `ASIOGetChannelInfo().name`, which RME /
  MOTU / Focusrite drivers do populate. But miniaudio has **no ASIO backend**, so
  it is a separate driver integration alongside the WASAPI capture path, and the
  Steinberg ASIO SDK is **GPLv3-or-proprietary** (since Nov 2025) — **incompatible
  with Loopy's MIT license** unless ASIO is an opt-in, user-supplied, non-vendored
  build component (or a paid Steinberg license is obtained).
- **Linux.** No stack — ALSA chmaps, PulseAudio, PipeWire ports, JACK aliases —
  exposes arbitrary per-channel labels; all are **positional** (FL/FR/AUX0…). The
  same Focusrite that advertises "Loopback" channels on macOS surfaces them as
  generic `AUX` ports on Linux, because Linux loopback is routing playback into a
  capture mux, not a labeled channel. A **PipeWire port-enumeration spike** is the
  single avenue worth a time-box, purely as a brittle, interface-specific `AUX`
  heuristic — not true label parity.

Approaches considered:

1. **Run-first, stub the label exclusion** — ship the portable core, document
   per-channel labels as macOS-only. Simplest, lowest risk. *Rejected as the sole
   target* because the user has RME/MOTU/Focusrite-class hardware on both OSes and
   explicitly wants maximum parity.
2. **Maximal: run both end-to-end + Windows ASIO opt-in + Linux PipeWire spike**
   (CHOSEN). Pursues every avenue each OS physically allows, with the portable core
   as the non-negotiable foundation and the native-label work clearly gated and
   degradable.

We chose the maximal approach but **strictly layered**: the portable end-to-end
work stands alone and ships first; ASIO and the PipeWire spike are additive, opt-in,
and must degrade cleanly to today's `return 0` (exclude-nothing) behavior when
unavailable.

## Key Decisions

- **Portable core is the foundation, shipped independently.** Windows + Linux
  building and running end-to-end via miniaudio (WASAPI on Windows;
  ALSA/PulseAudio/PipeWire on Linux) is its own deliverable. Everything else is
  additive. Rationale: it's the bulk of the user value and carries none of the
  licensing/feasibility risk.
- **Create the missing Linux app scaffold.** `loopy/linux/` does not exist; the
  engine plugin already declares `linux: { ffiPlugin: true }` and has
  `linux/CMakeLists.txt`. Need `flutter create --platforms=linux .` to generate the
  app-level GTK runner, then wire flavors. Windows scaffold already exists and is
  build-verified.
- **Verify portable loopback features on real hardware, both OSes.**
  `le_classify_capture_device` (device-name: "monitor of", virtual devices) and the
  latency-measurement harness are portable and are the practical loopback path.
  These get hands-on verification on the user's interfaces — not just a compile.
- **Windows per-channel labels via ASIO as an opt-in, non-vendored component.**
  Compile-time flag (off by default); the user/builder supplies the ASIO SDK
  locally. Reuse `le_label_is_loopback` verbatim against `ASIOChannelInfo.name`.
  Builds the same excluded-input bitmask as macOS. Rationale: only viable path on
  Windows; MIT license forbids vendoring the GPLv3 SDK.
- **Linux per-channel labels: documented OS limitation + a time-boxed PipeWire
  spike.** Default behavior stays `return 0` (exclude nothing); device-name
  classification still works. The spike enumerates capture-node ports
  (`PW_KEY_PORT_NAME` / `PW_KEY_AUDIO_CHANNEL`) to see if `AUX`-index heuristics buy
  partial parity on the user's specific interface. Keep only if it proves reliable.
- **Graceful degradation is mandatory everywhere.** When ASIO isn't built/available,
  or the PipeWire spike is inconclusive, the engine returns the current no-op mask.
  The feature becoming unavailable is correct behavior — the information genuinely
  isn't exposed.
- **No change to the FFI boundary's shape.** The ~40-function C ABI and the Dart
  loader (which already branches `.dll` / `.so` / `process()`) are stable; native
  label work lives entirely behind `le_compute_excluded_input_mask` and new
  platform-specific translation units, invisible to Dart.

## Open Questions

- **Build wiring for ASIO opt-in.** CMake option name, how the user points at a
  local ASIO SDK, and how the WASAPI capture path coexists with an ASIO-only probe
  (probe for labels via ASIO while still capturing via miniaudio/WASAPI, vs. running
  audio through ASIO too). Lean: ASIO used *only* as a label probe; capture stays on
  miniaudio. Confirm in planning.
- **ASIO label reliability.** `ASIOChannelInfo.name` is a 32-char, per-driver
  convention (~80% confidence it carries "Loopback"). Needs validation against the
  user's actual Windows interface early — a 30-minute spike de-risks the whole ASIO
  track before committing to the integration.
- **PipeWire spike success criteria.** Define up front what "good enough to keep"
  means (e.g. reliably flags the loopback `AUX` pair on the target interface with no
  false positives), and the hard time-box, so the spike can be cut cleanly.
- **PipeWire vs. ALSA/Pulse at runtime on the test machine.** miniaudio selects a
  backend dynamically; the PipeWire label spike needs `libpipewire` present and the
  node visible. Confirm the Linux test box runs PipeWire (vs. bare ALSA) so the
  spike is even applicable.
- **Linux flavors / packaging.** Loopy uses Flutter flavor schemes
  (`--flavor development`). Confirm how flavors map onto the Linux GTK runner and
  whether any packaging (AppImage/Flatpak/.deb) is in scope or deferred.
- **CI coverage.** Whether to add Windows + Linux build/test jobs so the portable
  engine can't silently regress. Likely yes, but scope (compile-only vs. headless
  smoke) is a planning decision. (Note: existing `flutter test` hook is broken — use
  the absolute Flutter path per repo gotchas.)
- **PR sequencing.** Strong candidate split: (1) Linux scaffold + both running
  end-to-end + portable-loopback verification; (2) Windows ASIO opt-in label
  exclusion; (3) Linux PipeWire spike (kept or documented-as-dead-end). Confirm in
  `/plan`.
