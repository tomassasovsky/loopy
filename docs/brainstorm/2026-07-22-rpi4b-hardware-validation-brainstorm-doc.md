---
date: 2026-07-22
topic: rpi4b-hardware-validation
---

# Raspberry Pi 4B hardware validation pass (floor-console Tier 2 stack)

Issue: #271. Prior research: `docs/research/2026-07-22-rpi5-embedded-boot-experience-research.md`.

## What We're Building

A **first on-hardware validation pass** for the floor-console software that
shipped in PRs #86–#93 but has never run on a real device. It runs on the
**substitute hardware available now** — a **Pi 4B**, booting from **SD card**, with
a **PC monitor + TV** standing in for the two touchscreens — and validates the
**existing GTK-on-Wayland (Tier 2 / Raspberry Pi OS) stack**, which is what runs
today without a Yocto build. Three functional goals, a **functional-smoke**
acceptance bar (not measured latency/thermal gates), driven **kiosk-first** (the
real appliance boot path), with a per-goal "drop to manual to isolate" fallback.

This validates the *current* stack on *current* gear; it deliberately does **not**
test the Pi 5, NVMe/SSD boot time, the GPIO/WS2812 floor-console controls, or the
Yocto tiers. Those are gated on hardware not yet in hand.

## Why This Approach

The user chose **kiosk-first**: install the shipped `deploy/rpi/` systemd unit +
labwc autostart + `pin-displays.sh` and boot straight into the appliance path, so
the thing under test is the real config rather than a hand-run approximation. The
risk of kiosk-first on a first-ever bring-up is that displays + audio + MIDI can
all fail at once behind a blank screen. We mitigate that — not by changing the
approach — but by attaching to each goal a **manual-isolation fallback** (SSH in,
run the subsystem by hand) so any single failure can be cornered without
abandoning the kiosk path.

## Scope & substitutions (Pi 4B now vs Pi 5 target)

| Aspect | Target (Pi 5 console) | This pass (Pi 4B, now) | Effect on validity |
|--------|-----------------------|------------------------|--------------------|
| Board | Pi 5 | **Pi 4B** | Functional parity; perf/thermal not representative |
| Boot medium | NVMe/SSD | **SD card** | Boot-*time* NOT under test here (that's a Tier-2 fast-boot concern) |
| Displays | 16″ touch + 7″ HDMI | **PC monitor + TV** (both micro-HDMI) | Dual-output logic valid; touch not tested; TV overscan/scale differs |
| Compositor | labwc | **labwc** (must confirm, not Wayfire) | Same — `wlr-randr` pinning needs labwc |
| GPIO chip | Pi 5 = `/dev/gpiochip4` | Pi 4 = **`/dev/gpiochip0`** | `gpio_client` default matches Pi 4; harmless here (no switches wired) |
| Controls | GPIO switches + WS2812 | **USB-MIDI pedal + its LEDs** | GPIO/LED path OUT of scope this pass |
| Audio | USB interface | **USB interface** | Full parity |

## The three validation goals

Acceptance bar for all three: **functional smoke** — "works cleanly, no glitches",
no measured latency/thermal numbers (those are deferred to real Pi 5 hardware).

### Goal 1 — Dual-display / multiple windows

- **What:** the app opens its main UI on one output (PC monitor = stand-in 16″) and
  the waveform second window on the other (TV = stand-in 7″), via
  `desktop_multi_window` under labwc, with `pin-displays.sh` mapping each by
  connector name.
- **How (kiosk-first):** set `LOOPY_MAIN_OUTPUT` / `LOOPY_WAVE_OUTPUT` in
  `pin-displays.sh` to the Pi 4's actual connectors (list with `wlr-randr` —
  expect `HDMI-A-1` / `HDMI-A-2`), tune `--scale` per panel, boot the kiosk.
- **Pass:** main UI fills the monitor, live waveform fills the TV, mapping is
  stable across a few reboots, no dark/half-blank output. The single-display and
  waveform-failed banners appear when a cable is pulled.
- **Isolate if it fails:** confirm labwc (not Wayfire) — `wlr-randr` must not error
  with "compositor doesn't support wlr-output-management"; run the app by hand
  under a manual labwc session; check `desktop_multi_window`/`window_manager` load.
- **Pi 4 gotchas:** TVs often **overscan** — set the TV to "Just Scan"/1:1 or use
  `disable_overscan`; the two micro-HDMI ports enumerate as `HDMI-A-1/2`.

### Goal 2 — USB-MIDI foot pedal (detection, input, LED feedback)

- **What:** the existing Pro Micro / 32U4 USB-MIDI pedal (with onboard LEDs wired)
  is detected, selected cleanly by `midi_client`, its footswitches drive looper
  actions (MIDI in), and the app lights the pedal's LEDs via MIDI out.
- **How (kiosk-first):** pedal plugged in at boot; it enumerates as an ALSA-seq
  MIDI client; the app's saved MIDI mapping (MIDI-CC `ControllerMapping` defaults)
  routes switches → actions; app state → MIDI out → pedal LEDs.
- **Pass:** pedal appears + is auto-selected (no manual re-pick each boot); every
  footswitch fires the right action with no missed/double triggers; LEDs track app
  state (record/overdub/stop/clear) with no visible lag.
- **Isolate if it fails:** `aconnect -l` / `amidi -l` to confirm the OS sees the
  device; watch raw MIDI in; verify the app sends MIDI out for LED feedback (is the
  app→pedal LED channel actually wired end-to-end?).
- **Open risk:** whether app→pedal **LED feedback** is fully wired end-to-end (vs
  switches-in only) — flagged for the plan to confirm against the pedal firmware +
  `midi_client` / pedal_repository out path.

### Goal 3 — USB audio interface out of the box

- **What:** a class-compliant USB interface passes audio in/out cleanly through the
  miniaudio engine on Pi OS.
- **The critical gotcha (from `docs/RUNNING_ON_LINUX.md`):** on a PipeWire system
  miniaudio's **PulseAudio backend returns silent capture** — the engine therefore
  prefers **JACK** (JACK → PulseAudio → ALSA), which uses **PipeWire's JACK server
  (`pipewire-jack`)**. So goal 3 requires `pipewire-jack` present, and the user must
  **select the interface as BOTH input and output** so the engine pins its JACK
  ports to that device (otherwise miniaudio aggregate-auto-connect puts channels on
  the wrong hardware / picks a "Monitor of…" source as input).
- **Pass:** input is heard (not silence — the PulseAudio-silent-capture trap is
  avoided), output plays, a loop records + plays back cleanly, xrun-free at a
  comfortable buffer (expect to need a **larger buffer on Pi 4**, e.g. 256→512).
- **Isolate if it fails:** `pw-record`/`arecord` to prove the OS captures audio;
  confirm `pipewire-jack` installed; check the engine landed on the JACK backend
  (not PulseAudio) and that the interface is selected as in+out.

### First-run device setup (a kiosk-first wrinkle to resolve in the plan)

The kiosk bundle builds with `--dart-define=LOOPY_CONSOLE=true`, which hides the
**tracks transport chrome** (pedals own it) — but the audio/MIDI **device-selection
settings** must remain reachable so a first boot can pin the interface + pedal;
`tryAutoStartEngine` then auto-starts them on later boots. If the only path to
Audio/MIDI settings is chrome that console mode hides, first-run setup is blocked.
**Plan must confirm the in-kiosk path to device selection** (mouse on the monitor)
or prescribe a first-run **non-console** launch to pin devices, then switch to the
console kiosk.

## VST3 plugins on the Pi build options (documented answer — not tested this pass)

**The host is fine; the plugins are the ceiling.** Loopy's VST3/CLAP hosting stack
(shipped, incl. the Linux port; MIT VST3 SDK; repo is GPLv3) is our own C++ and
**cross-compiles to `linux-aarch64` like the rest of the engine**. The hard limit
is that a VST3 is **native per-architecture code**: only plugins built for
**`linux-aarch64`** can load on a Pi. Almost all commercial VST3s ship x86_64 (and
mac) only — so on **any** Pi build you can host **aarch64-native plugins**
(a handful of open source ones) and essentially none of a typical x86 collection.
That ceiling is independent of the OS tier.

Per build option, the differences are about the **plugin editor GUI** and
**headroom**:

- **Tier 2 (Pi OS / GTK-on-labwc):** host runs; aarch64 VST3s load. A plugin's
  native **editor window** on Linux is an X11/embedded surface, so under Wayland
  (labwc) editor GUIs need **XWayland**. **Headless / parameter-only** hosting
  (drive plugin params from Loopy's own knob UI, no native plugin GUI) works
  without it. **Pi 4 headroom is tight** — a couple of light effects are fine;
  heavy DSP (convolution, big reverbs) will struggle. Pi 5 is more comfortable
  (the RPi doc already flags plugin hosting as where Pi 4 headroom runs out).
- **Tier 3a (Yocto + GTK):** same host + aarch64-plugin story as Tier 2, but you
  must **bake the plugin runtime deps into the image** (XWayland + X libs for
  editors, plus whatever a given plugin links) — more image-integration work.
- **Tier 3b (Yocto + ivi-homescreen):** host still runs (native C++), but
  ivi-homescreen is a minimal Wayland embedder with **no native path to surface an
  arbitrary X11 plugin editor window** — so 3b realistically means **headless /
  parameter-only** plugin use. Adding XWayland to surface editors fights the
  minimal-stack premise that makes 3b fast. Net: **3b favors GUI-less plugin use.**

**Takeaway:** VST3 on Pi is a "possible for aarch64-native plugins, editor-GUI
constrained (XWayland on Tier 2/3a; GUI-less on 3b), headroom-limited on Pi 4"
feature — **not** a "run your existing plugin collection" feature. Worth a small
dedicated spike (find/compile one aarch64 VST3, host it headless) once the core
three goals pass — but out of scope for this hardware pass.

## Key Decisions

- **Validate the Tier 2 GTK-on-Wayland stack on the Pi 4B now** — it's what runs
  today without a Yocto build; Tier 3 validation waits for that image + Pi 5.
- **Kiosk-first**, with a per-goal manual-isolation fallback — test the real
  appliance path, but keep a way to corner single-subsystem failures.
- **Functional-smoke acceptance**, no measured latency/thermal gates — Pi 4B + SD
  numbers wouldn't represent the Pi 5 target, so measuring them now would mislead.
- **Scope = 3 goals (dual-display, USB-MIDI pedal + LEDs, USB audio).** GPIO/WS2812
  floor-console controls and boot-time are explicitly excluded (hardware/medium not
  representative).
- **VST3 = documented only** this pass; the answer above; hands-on deferred to a
  small aarch64 spike after the three goals pass.

## Open Questions (for planning)

1. **Console-mode device setup:** exact in-kiosk path to reach Audio/MIDI device
   selection in a `LOOPY_CONSOLE` build, or prescribe a first-run non-console
   launch to pin devices. (Blocks goals 2 & 3 on first boot.)
2. **Pedal LED feedback path:** confirm app→pedal **MIDI-out LED** feedback is
   wired end-to-end (not just switches-in) against the pedal firmware +
   `midi_client`/pedal_repository. If not, LED validation degrades to "switches
   only" for this pass.
3. **labwc on Pi 4 Bookworm:** confirm the image runs **labwc** (not Wayfire) so
   `wlr-randr` output-pinning works; document the `raspi-config` switch if needed.
4. **Build method — RESOLVED: cross-compile on PC.** Wrinkle: the dev machine is a
   **Mac**, and macOS cannot build Linux desktop bundles. So "cross-compile" =
   build in an **arm64 Linux container** (native speed on Apple Silicon; qemu on
   Intel), mirroring the CI `build-linux-arm64` dependency set (ninja,
   libgtk-3-dev, libasound2-dev, clang, cmake, …), producing
   `build/linux/arm64/release/bundle`, then `scp` to the Pi. **Plan deliverable: a
   containerized aarch64 build script** (none exists in the repo yet). Release
   build, `--dart-define=LOOPY_CONSOLE=true` for the kiosk bundle.
5. **Connector naming stability** on the Pi 4's two micro-HDMI ports across reboots
   (the output-swap race `pin-displays.sh` guards) — verify with the monitor+TV.
6. **Audio interface — RESOLVED: Focusrite (Clarett/Scarlett).** The best-trodden
   path (`RUNNING_ON_LINUX.md` was written against a Clarett+ 8Pre). Plan defaults
   to **512 frames** on Pi 4 for xrun-free headroom; select as input+output for
   JACK port pinning.
