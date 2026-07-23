---
title: "Raspberry Pi 4B hardware validation (aarch64 build tooling + kiosk runbook)"
type: chore
date: 2026-07-22
---

## Raspberry Pi 4B hardware validation (aarch64 build tooling + kiosk runbook) - Standard

Issue: #271 (parent direction issue; this pass gets two child issues — see Tracking) · Brainstorm: `docs/brainstorm/2026-07-22-rpi4b-hardware-validation-brainstorm-doc.md` · Research: `docs/research/2026-07-22-rpi5-embedded-boot-experience-research.md`

> Revised after `/plan-technical-review` (2026-07-23): folded in the three review agents' findings — corrected the "CI-verifiable" overclaim, fixed the two-`Closes` tracking conflict, collapsed the build tooling to two files under `deploy/rpi/build/`, completed the container deps, and made the runbook delta against the existing checklist instead of restating it.

## Overview

First **on-hardware validation** of the floor-console software (PRs #86–#93), which
has never run on a real device. It runs on the substitute gear available now — a
**Pi 4B**, **SD card**, and a **PC monitor + TV** for the two panels — and validates
the existing **Tier 2 GTK-on-Wayland stack** (what runs today, no Yocto),
**kiosk-first**, at a **functional-smoke** bar.

Two deliverables, each its own PR:

1. **Containerized aarch64 build tooling** (NEW) — the dev machine is a Mac (can't
   build Linux bundles), so builds run in an **arm64 Linux container**, producing the
   release bundle to `scp`/`rsync` to the Pi.
2. **Pi 4B kiosk-first validation runbook** — extends the on-device checklist already
   in `docs/RUNNING_ON_RPI.md` with the Pi-4-only deltas + the 3 goals + a results
   table. Executing it is `blocked-verify`; results get recorded back into it.

VST3 is **documented-only** (answered in the brainstorm + research doc); no plugins are
tested this pass.

## Problem Statement / Motivation

Every native/hardware path in PRs #86–#93 (labwc kiosk, `desktop_multi_window`
dual-display, `midi_client` pedal in + `pedal_repository` MIDI-out LED feedback,
miniaudio→JACK/ALSA audio) is written but **UNVERIFIED on hardware**. Before any Pi 5
/ Yocto investment, prove the core stack works on the gear in hand. There is also **no
way to build an aarch64 bundle from a Mac** today — that gap blocks every on-device
step, so it is deliverable #1.

## Proposed Solution

### Deliverable 1 — Containerized aarch64 build (PR-1, independent)

**Two** files under `deploy/rpi/build/` (all Pi tooling already lives under
`deploy/rpi/`, so no new top-level `tool/` taxonomy):

```
deploy/rpi/build/Dockerfile.arm64        # arm64v8/ubuntu:24.04 + deps + Flutter 3.44.4
deploy/rpi/build/build-arm64-bundle.sh   # docker build+run; passthrough extra args; optional --deploy user@host
```

- **Base** `arm64v8/ubuntu:24.04`. Install the **CI dep set**
  (`.github/workflows/main.yaml` `build-linux-arm64`): `ninja-build libgtk-3-dev
  libglib2.0-dev libpango1.0-dev libasound2-dev clang cmake pkg-config` — **plus the
  packages a bare container lacks that the CI runner ships preinstalled**: `git curl
  unzip xz-utils ca-certificates libstdc++6`. (Without these, Flutter's git bootstrap +
  first-run SDK fetch fail in a clean container.)
- Flutter **3.44.4** (repo-pinned), `flutter config --enable-linux-desktop`,
  `flutter pub get`.
- **Build:** `flutter build linux --release --target lib/main_production.dart
  --dart-define=LOOPY_CONSOLE=true`.
  - The `main_*` entrypoints are **byte-identical on Linux** (no flavored CMake
    configs — `RUNNING_ON_RPI.md:87`); `main_production` is a naming choice, not a
    behavior change. **All three build commands must agree** (see the deploy-doc fix
    below).
  - **Non-console** build (for first-run device setup, if needed) is just **omitting
    the define** — the script forwards any extra `--dart-define=…`/args to
    `flutter build` (passthrough), matching `deploy/rpi/README.md`'s existing "omit the
    define for a normal desktop build" convention. No bespoke flag.
- **Output** `build/linux/arm64/release/bundle/` (`loopy` + `libloopy_engine.so` +
  `lib/` + `data/`; path confirmed against `autostart:16` `LOOPY_BIN`). Optional
  `--deploy pi@<host>` runs `rsync -avz build/linux/arm64/release/bundle/
  pi@<host>:~/loopy/build/linux/arm64/release/bundle/`.
- On Apple Silicon the arm64 container runs natively; on Intel, under qemu (slower).

**Honest CI-coverage note (was an overclaim):** CI only ever builds `--debug --target
lib/main_development.dart` — so this container reuses the **proven CI *dependency
set***, but the **`--release` + console *invocation* is NEW and unproven by CI**
(Linux `--release` runs nowhere in CI). To catch drift, the script also runs the
**exact CI debug command** as a parity smoke before the release build. CI's existing
`build-linux-arm64` job remains the compile guard; the container is a **local-dev**
producer, not a CI gate.

**Also in PR-1 (fixes a real latent bug):** `deploy/rpi/README.md:29` and
`deploy/rpi/compositor/labwc/autostart:14` show `flutter build linux --release
--dart-define=LOOPY_CONSOLE=true` with **no `--target`** — which **fails** because
`lib/main.dart` does not exist. Add `--target lib/main_production.dart` to both so all
build commands agree.

### Deliverable 2 — Kiosk-first validation runbook (PR-2, docs)

Extend `docs/RUNNING_ON_RPI.md` **in place** (its checklist at lines 182–223 already
covers labwc/`wlr-randr`, overscan, single-display banner, reboot stability for the Pi
5 case). The new content is a **Pi-4B section that deltas against that checklist**, not
a restatement:

#### Pre-flight (Pi-4B deltas + resolve-before-boot)

- **Compositor = labwc, not Wayfire** (`raspi-config` → Wayland → labwc); `wlr-randr`
  must list outputs (same check as the existing checklist).
- **`pipewire-jack` present** — goal 3 needs the JACK backend (PulseAudio backend =
  silent capture, `RUNNING_ON_LINUX.md`). Confirm the app lands on JACK.
- **Power / USB (Pi 4 specifics):** powered USB hub for the Focusrite (Pi 4 port
  current budget); the pedal's **LEDs need external 9V** (USB-MIDI carries LED *frames*
  only); official 5V/3A PSU (`vcgencmd get_throttled` == `0x0`).
- **Connectors:** Pi 4 = 2× micro-HDMI → `HDMI-A-1`/`HDMI-A-2`; set
  `LOOPY_MAIN_OUTPUT`/`LOOPY_WAVE_OUTPUT` + `--scale` in `deploy/rpi/pin-displays.sh`;
  **TV overscan** → "Just Scan"/1:1 or `disable_overscan=1`.
- **First-run device setup:** `LOOPY_CONSOLE` hides the transport chrome; device
  pickers are in **Settings** (right-click / `S`). Bind (a) **MIDI FOOT CONTROLLER**
  input, (b) **PEDAL LINK** output, (c) **Audio** interface as **both in and out** @
  **512 frames**; these persist (`tryAutoStartEngine` + hotplug reconnect). **Open-Q
  #1:** confirm Settings is reachable in a console build; if not, first-run with a
  non-console bundle (omit the define — no new tooling).

#### Goals (procedure / functional-smoke pass / manual-isolation fallback)

- **Goal 1 — Dual-display:** main UI on the monitor, waveform on the TV via
  `desktop_multi_window` + `pin-displays.sh`. Pass: both render, stable across ≥3
  reboots, pull-cable shows the single-display/waveform-failed banner. Isolate: confirm
  labwc; run the bundle by hand under manual labwc; check the three window plugins load.
- **Goal 2 — USB-MIDI pedal:** input = CC 80/81/82/83 on track 0 (`MidiControllerSource`);
  LED out = `pedal_repository`→`NativePedalTransport`→`MidiOutClient`. Pass:
  auto-selected each boot, every switch fires correct action (one stomp = one action),
  LEDs track state, hotplug re-attaches without engine restart. Isolate: `aconnect -l`/
  `amidi -l`; confirm PEDAL LINK bound + 9V rail on; on-screen faceplate mirrors intended
  LEDs (isolates firmware vs app).
- **Goal 3 — Focusrite audio:** selected as in+out @512. Pass: input **heard, not
  silent** (proves JACK backend + port pinning), loop records/overdubs/plays back
  xrun-free, channels on the right interface (not a "Monitor of…" source). Isolate:
  `pw-record`/`arecord`; verify `pipewire-jack` + JACK-backend selection.

#### cspell (PR-2)

Add the runbook's new terms missing from `.github/cspell.json` — confirmed absent:
`wlr`, `aarch64`, `overscan`, `Wayland`, `Bookworm`, `rsync` (run the gate to catch any
others; script-only terms like `arm64v8` are not scanned — CI spell-checks `**/*.md`
only).

### VST3 (documented only)

Link the brainstorm §VST3 + research doc §4.3 from the runbook: host cross-compiles to
aarch64; ceiling is aarch64-native plugin availability; editor GUIs need XWayland (Tier
2/3a) or are GUI-less (3b); Pi 4 headroom tight. A small aarch64 plugin spike is a
**follow-up issue**, not this pass.

## Technical Considerations

- **No app-code changes.** Deliverable 1 = build/deploy tooling + a 2-line deploy-doc
  fix; deliverable 2 = docs + cspell entries + possibly `pin-displays.sh` connector env.
- **Blocked-verify:** goals 1–3 can't run in CI (no display/audio/MIDI). The runbook +
  a filled-in results table are the evidence.

## Success Criteria

```success-criteria
GOAL: Prove the Tier 2 GTK-on-Wayland floor-console stack runs on a Pi 4B (SD, monitor+TV) at a functional-smoke bar, and provide a repeatable aarch64 build from a Mac.

SUCCESS CRITERIA:
- CI arm64 compile guard stays green (existing job; deploy-doc fix doesn't break it) | verify: flutter analyze
- Runbook + docs pass spell-check (new terms added to cspell) | verify: npx --yes cspell "docs/**/*.md"
- [local-dev, needs Docker] container emits an aarch64 release bundle | verify: manual 1) run deploy/rpi/build/build-arm64-bundle.sh 2) file build/linux/arm64/release/bundle/loopy | grep 'ARM aarch64'
- Deploy-doc build commands all carry --target and succeed | verify: manual 1) grep -n "flutter build linux" deploy/rpi/README.md deploy/rpi/compositor/labwc/autostart 2) confirm each has --target lib/main_production.dart
- Goal 1 dual-display (see Proposed Solution §Goal 1) | verify: manual 1) boot kiosk 2) both outputs render 3) reboot 3x, mapping holds 4) unplug TV, banner appears
- Goal 2 USB-MIDI pedal (see §Goal 2) | verify: manual 1) bind both pickers 2) reboot, auto-selected 3) stomp CC80-83, correct actions 4) LEDs follow state 5) replug re-attaches without engine restart
- Goal 3 Focusrite audio (see §Goal 3) | verify: manual 1) select in+out @512 2) input audible not silent 3) record+overdub+playback 4) no xruns
- VST3 answer linked from the runbook (no hands-on test) | verify: manual 1) runbook links brainstorm/research VST3 section

NON-GOALS:
- GPIO footswitches / WS2812 controls (gpio_client/led_client) — not wired
- Boot-time / NVMe / SSD measurement — SD card, not representative
- Pi 5 and Yocto Tier 3a/3b validation — hardware/image unavailable
- Measured latency / thermal gates — Pi 4B + SD wouldn't represent the Pi 5 target
- Hands-on VST3 plugin hosting — documented only

VERIFICATION COMMAND: flutter analyze && npx --yes cspell "docs/**/*.md"
```

> The container build is intentionally a `verify: manual` local-dev step (needs Docker
> on the Mac); the existing CI `build-linux-arm64` job is the compile guard, so the
> plan's CI-lane VERIFICATION COMMAND does not depend on Docker.

## Success Metrics

All three goals reach a functional-smoke pass on the Pi 4B, recorded in the runbook's
results table (pass/fail + notes per goal), and a Mac can produce the aarch64 bundle in
one command.

## Dependencies & Risks

**PR split (independently mergeable — confirmed by plan-splitting review):**

- **PR-1 — build tooling** (`deploy/rpi/build/*` + the 2-line deploy-doc `--target`
  fix). **`Closes #<tooling-issue>`**, `autonomy:merge-gate`. No dependency on PR-2.
- **PR-2 — runbook doc + cspell** (`docs/RUNNING_ON_RPI.md`, `.github/cspell.json`).
  **`Closes #<runbook-issue>`**, doc merge is `autonomy:merge-gate`; the *validation
  work it describes* is `autonomy:blocked-verify`.

**Tracking fix (was a conflict — two PRs both `Closes #271`, and one issue can't hold
two autonomy labels, `docs/TRACKING.md:35`):** #271 stays the **parent direction
issue**; file **two child issues** at build time — one for the tooling (`merge-gate`),
one for the runbook/validation (`blocked-verify`) — each closed by its own PR, both
`Refs #271`.

**Risks:** first-run setup blocked under `LOOPY_CONSOLE` (mitigation: non-console
bundle via `--dart-define` omission — no new code); Pi 4 USB power for the Focusrite
(powered hub); TV overscan; Wayfire-instead-of-labwc breaking `wlr-randr`; pedal 9V LED
rail off → LEDs dark despite correct MIDI; release-mode GTK build unproven by CI
(mitigation: CI-parity debug build in the container).

## References & Research

- Kiosk config: `deploy/rpi/loopy-kiosk.service`, `deploy/rpi/compositor/labwc/{autostart,rc.xml}`, `deploy/rpi/pin-displays.sh`
- Audio backend gotcha: `docs/RUNNING_ON_LINUX.md` (JACK preference, silent-capture, port pinning)
- CI arm64 recipe: `.github/workflows/main.yaml` `build-linux-arm64` (`--debug --target lib/main_development.dart`)
- Broken deploy build cmd: `deploy/rpi/README.md:29`, `deploy/rpi/compositor/labwc/autostart:14` (no `--target`)
- Entrypoints identical on Linux: `lib/main_{development,production,staging}.dart`; `RUNNING_ON_RPI.md:87`
- MIDI pedal: `docs/MIDI_FOOT_CONTROLLER.md` (CC 80–83); LED-out `packages/pedal_repository/lib/src/native_pedal_repository.dart`, `lib/pedal/cubit/pedal_cubit.dart`
- Console mode: `lib/common/console_mode.dart:14`
- Dual-display: `lib/visualizer/waveform_window_service.dart`; single-display fallback `lib/app/view/app.dart:369`
- VST3 on Pi: brainstorm §VST3 + research §4.3
- Related: PRs #86–#93 (floor-console), #85 (USB-MIDI pedal), #202 (Linux native audio)
</content>
