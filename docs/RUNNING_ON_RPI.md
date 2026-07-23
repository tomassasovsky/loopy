# Running Loopy on a Raspberry Pi 5 (floor-console target)

Loopy's Raspberry Pi 5 build is the same native Linux/GTK runner described in
[RUNNING_ON_LINUX.md](RUNNING_ON_LINUX.md), compiled for `arm64`. Pi OS uses the
same PipeWire → JACK → ALSA audio path, so **that doc is the source of truth for
audio**; this doc covers only what is Pi-specific: building an `arm64` bundle,
bringing it up on the device, and the two architecture decisions that gate the
dual-display work in later parts (kiosk rendering target and Wayland compositor).

This is Part 1 of the floor-console effort. Its job is to de-risk the highest-cost
unknowns **before** any panels or enclosure work begin.

## Decision 1 — Kiosk rendering target: **GTK-on-Wayland** (the Flutter Linux runner)

**Decision: ship the existing Flutter Linux GTK runner on Wayland. Do not use
`flutter-pi`.**

Rationale:

- The waveform display is a **second OS window**, opened by
  [`WaveformWindowService`](../lib/visualizer/waveform_window_service.dart:29) via
  `desktop_multi_window`, with window placement controlled through
  `window_manager`. Both packages assume a desktop windowing environment (GTK).
- `flutter-pi` is lighter and boots straight to fullscreen on KMS/DRM, but it is a
  single-window embedder with no `desktop_multi_window` / `window_manager`
  support. Adopting it would mean reimplementing the second-window path, which
  would invalidate the dual-display design that Parts 5–7 build on.
- The GTK runner already forces the Skia renderer (Impeller mis-rasterizes the
  Material icon font as "tofu") in
  [`linux/runner/main.cc:15`](../linux/runner/main.cc) — no `flutter run` flag is
  needed, and that fix carries to `arm64` unchanged.

The only argument for `flutter-pi` is performance/boot time; revisit it **only**
if GTK-on-Wayland cannot hold the ~30 fps second-window push on a Pi 5, and only
after a path exists to keep two windows working under it.

> On-device status: **pending hardware.** The second-window open/control check is
> in the verification checklist below.

## Decision 2 — Wayland compositor: **labwc** (wlroots-based)

**Decision: target `labwc`. Avoid Wayfire. `sway` is the fallback.**

Rationale:

- Part 5 pins the waveform window to a specific physical output by output name at
  boot. That requires the compositor to expose the
  `wlr-output-management-unstable-v1` protocol (the protocol `wlr-randr` and
  `kanshi` speak). Without it there is no deterministic, scriptable way to map a
  window to a named output.
- `labwc` is **wlroots-based** and, as of the October 2024 Raspberry Pi OS
  release, is the **default Wayland compositor across the Pi range, including the
  Pi 5** (it replaced Wayfire). Being the OS default means it is the
  best-supported, least-surprising target.
- **Wayfire** (the previous Pi OS default) does not expose
  `wlr-output-management`, so `wlr-randr`-based output pinning does not work on it
  — it is explicitly avoided.
- `sway` is also wlroots-based and supports `wlr-output-management`; it is the
  fallback if a labwc-specific blocker appears.

> On-device status: **pending hardware.** `wlr-output-management` exposure must be
> confirmed with `wlr-randr` on the actual image (see checklist).

## Building an `arm64` bundle

CI builds this on every PR via the `build-linux-arm64` job in
[`.github/workflows/main.yaml`](../.github/workflows/main.yaml) — a compile-only
guard on a native `arm64` runner, mirroring the x86_64 `build-linux` job (no audio
runs in CI). To build on a Pi 5 (Pi OS, `arm64`) directly:

1. Install the GTK + audio build dependencies (same set as CI):

   ```bash
   sudo apt-get update
   sudo apt-get install -y ninja-build libgtk-3-dev libglib2.0-dev \
     libpango1.0-dev libasound2-dev clang cmake pkg-config
   ```

2. Install Flutter `3.44.x` (the version pinned across every build job) and enable
   the Linux desktop:

   ```bash
   flutter config --enable-linux-desktop
   flutter pub get
   ```

3. Build the development flavor (debug, compile-only — no `--flavor` on Linux, the
   CMake desktop build has no flavored configs):

   ```bash
   flutter build linux --debug --target lib/main_development.dart
   ```

   The native engine builds as `libloopy_engine.so` and is bundled alongside the
   `loopy` binary. The Skia force in `main.cc` means icons render correctly with
   no extra flags.

For audio bring-up on the device (interface selection, JACK/PipeWire quantum,
latency calibration) follow [RUNNING_ON_LINUX.md](RUNNING_ON_LINUX.md) verbatim —
nothing changes on `arm64`.

## Kiosk boot + dual-display

The console boots straight into Loopy full-screen across both panels (16″ main
UI, 7″ waveform) under labwc, with no keyboard or mouse. The systemd unit,
compositor config, and the deterministic output-pinning script live in
[`deploy/rpi/`](../deploy/rpi/README.md) — follow that README to install them and
to set your real connector names with `wlr-randr`.

How the display edge cases are handled (all in [`run_loopy.dart`](../lib/app/run_loopy.dart)
+ the app shell, so they are exercised in widget tests):

- **Deterministic pinning.** `deploy/rpi/pin-displays.sh` pins each output by
  connector name, so the 16″ and 7″ never swap across reboots. Verify the
  mapping holds across **≥5 reboots** — that is the real acceptance gate.
- **Second-window failure is visible.** If the waveform window does not become
  ready, the app shows an operator banner instead of degrading to a dark screen
  (`WaveformWindowService.open()` now returns readiness;
  [`waveform_window_service.dart`](../lib/visualizer/waveform_window_service.dart)).
- **Single-display fallback.** With only one display connected the app skips the
  waveform window and shows a notice — no half-blank console.
- **Per-display scale.** Set with `wlr-randr --scale` in `pin-displays.sh`; tune
  per panel after the Part-6 HDMI-vs-DSI choice.

## Power-cut resilience (read-only root + supervision)

A stompable unit gets its power cut mid-set, so the appliance is hardened against
it (config in [`deploy/rpi/`](../deploy/rpi/README.md)):

- **App/compositor supervision.** The `loopy-kiosk` systemd unit respawns the
  whole kiosk on any crash (`Restart=always`, with a generous start-limit budget
  for a keyboard-less unit). On relaunch the app cleans up any orphaned waveform
  sub-window itself via `closeOrphanWindows()` in
  [`run_loopy.dart`](../lib/app/run_loopy.dart) — no orphan window survives a
  respawn.
- **Read-only root + writable data partition.** `/` runs read-only (overlay), so
  a power-cut can't corrupt the OS; app settings + sessions live on a separate
  writable partition. Setup + the **≥20-cycle power-cut stress test** (the real
  acceptance gate) are in [`deploy/rpi/overlayfs/README.md`](../deploy/rpi/overlayfs/README.md).
- **Boot integrity check.** `start-kiosk.sh` runs `boot-integrity-check.sh`
  before the UI: it fscks + mounts the writable partition, and on an
  unrecoverable card shows a **"needs attention" screen** on the console instead
  of a black display or a half-broken app.
- **Durability scope.** The target is **no SD corruption**, *not* zero loop
  loss — a read-only root protects the OS, not unsaved musical work. Live-loop
  checkpoint/restore is a separate, product-wide concern.

> Record the power-cut stress run (pass/fail per cycle, any fsck repairs) here
> once verified on hardware.

## Raspberry Pi 4 Model B (8GB) vs Pi 5

The console targets a Pi 5, but the software is portable arm64 + standard
peripherals and runs on a **Pi 4 Model B 8GB** with no code changes:

- **Displays** — Pi 4 has 2× micro-HDMI; labwc/Wayland + `wlr-randr` run on it.
- **LED driver** — external RP2040 over UART (GPIO14/15), Pi-model-agnostic.
- **Caveats are performance, not compatibility.** The Pi 4 CPU is ~2–3× slower,
  so the ≤10 ms audio round-trip target is tighter — expect to use a slightly
  larger buffer (256→512 frames) for xrun-free operation — and a stompable
  always-on unit needs **active cooling**. Use a USB 3.0 port for the interface.
  Plugin (VST3/CLAP) hosting on the console would be where Pi 4 headroom gets
  tight; the core loopstation is comfortable.

## Hardware (enclosure, protection, power, BOM)

The console's hardware design lives under [`hardware/`](../hardware):

- **BOM / shopping list:** [`hardware/loopy_console_shopping_list.md`](../hardware/loopy_console_shopping_list.md)
  (Argentina-sourced) — Pi 5 + active cooler, 16″ touchscreen, **7″ HDMI**
  display, USB interface, footswitches, EC11 encoder, WS2812 ring + strip, the
  RP2040 LED driver, and power.
- **Power/thermal budget + enclosure intent:**
  [`hardware/console/README.md`](../hardware/console/README.md) — the per-rail
  power budget and the active-cooling requirement.

**7″ display decision: HDMI (not DSI).** Both screens are HDMI, so they
enumerate as `HDMI-A-1` / `HDMI-A-2` and pin cleanly via `wlr-randr` (Part 5's
`pin-displays.sh`), with no DSI compositor mapping. DSI's only gain — freeing a
micro-HDMI — is moot here. Set the 7″ per-output `--scale` to taste.

## On-device bring-up checklist (run on a Pi 5)

These cannot be verified in CI (no display, no audio). Tick them when the panels
and a Pi 5 are available:

- [ ] An `arm64` Loopy bundle launches full-screen on the Pi 5 under labwc.
- [ ] Material icons render correctly (not "tofu" boxes) — confirms the Skia path
      in [`main.cc`](../linux/runner/main.cc) works on `arm64`.
- [ ] The waveform second window opens and is controllable under GTK-on-Wayland
      (`desktop_multi_window` + `window_manager` work on the device).
- [ ] `wlr-randr` lists the connected outputs under labwc — confirms
      `wlr-output-management` is exposed for the Part 5 output-name pinning:

      ```bash
      wlr-randr
      ```

      If this errors with "compositor doesn't support
      wlr-output-management-unstable-v1", the image is running Wayfire — switch to
      labwc (or sway) before proceeding.
- [ ] Audio captures and plays back per [RUNNING_ON_LINUX.md](RUNNING_ON_LINUX.md)
      with the chosen USB interface.
- [ ] Cold boot lands on the app full-screen with **16″ = main UI, 7″ =
      waveform**, with no keyboard/mouse (the `loopy-kiosk` systemd unit).
- [ ] The display mapping is stable across **≥5 reboots** (no output-naming
      race) — adjust `deploy/rpi/pin-displays.sh` connector names if it flips.
- [ ] Disconnecting the 7″ shows the single-display notice; a failed second
      window shows the waveform-failed banner (no silent dark screen).
- [ ] Both panels render at a usable scale (tune `--scale` per panel).
- [ ] Killing the app → it respawns within the budget; no orphan waveform
      window remains on the 7″.
- [ ] **Hard power-cut ×20 mid-session → no SD corruption** (read-only root +
      boot integrity check); record results above.
- [ ] A corrupted writable partition boots to the "needs attention" screen, not
      a black display.
- [ ] **≤10 ms round-trip audio latency** re-measured on the chosen USB
      interface + Pi 5 + PipeWire quantum (48 kHz / Pro Audio profile); record
      the figure here.
- [ ] **≥2 h thermal soak** (audio + dual-display + GPU, closed enclosure):
      `vcgencmd get_throttled` stays `0x0`, no xrun-rate regression; record
      results here.
- [ ] Stompable footswitch panel survives stage-abuse testing.

## Pi 4B validation pass (substitute gear: SD + monitor + TV)

First **on-hardware** run of the floor-console stack (PRs #86–#93) — the labwc
kiosk, `desktop_multi_window` dual-display, the `midi_client` pedal-in +
`pedal_repository` LED-out path, and the miniaudio→JACK audio — none of which has
run on a real device yet. It uses the gear on hand — a **Pi 4B**, an **SD card**,
and a **PC monitor + TV** for the two panels — to validate the **Tier 2
GTK-on-Wayland** stack (what ships today; no Yocto), **kiosk-first**, at a
**functional-smoke** bar.

This is a **delta** against the Pi 5 bring-up checklist above, not a replacement:
the labwc / `wlr-randr` / overscan / single-display / reboot-stability checks are
shared. Because it runs off an SD card on the slower Pi 4 CPU, the boot-time,
NVMe, latency, and thermal gates are **not** representative — those stay Pi-5-only.
Executing this pass is **hardware-gated**; record outcomes in the results table at
the end. Build the `aarch64` bundle with `deploy/rpi/build/build-arm64-bundle.sh`
(the Mac cannot build a Linux bundle natively; see
[`deploy/rpi/README.md`](../deploy/rpi/README.md)).

### Pre-flight (resolve before boot)

- **Compositor = labwc, not Wayfire.** `raspi-config` → Advanced → Wayland →
  **labwc**. As above, `wlr-randr` must list the outputs; if it errors with
  "compositor doesn't support wlr-output-management-unstable-v1" the image is still
  on Wayfire and output pinning will not work.
- **`pipewire-jack` present, and launch via `pw-jack`.** Goal 3 needs Loopy to
  land on the **JACK** backend; the PulseAudio backend captures silence (see
  [RUNNING_ON_LINUX.md](RUNNING_ON_LINUX.md)). Install `pipewire-jack`, and run the
  binary under **`pw-jack`** (`pw-jack …/loopy`) — without it the engine loads the
  real `libjack`, finds no running `jackd`, and **hangs retrying** (`Cannot connect
  to server socket … jack server is not running`). The kiosk `autostart` already
  wraps the launch in `pw-jack`; confirm the app selects JACK, not "Monitor of …".
- **Sample rate must match the interface, and use "Pro Audio".** Set the card's
  profile to **Pro Audio** (raw channels, not `analog-surround`) and pick the app
  **sample rate to match what the device actually runs** (check with `pw-top` — both
  the interface and `dev.loopy.loopy` nodes should show the same RATE). A mismatch
  (e.g. app @ 96 k, device @ 48 k) makes PipeWire insert a **resampler** that adds
  latency and xruns (climbing `ERR` in `pw-top`). Pin the CPU governor to
  `performance` to kill DVFS jitter.
- **Power / USB (Pi 4 specifics).** Use a **powered USB hub** for the Focusrite —
  the Pi 4's per-port current budget is tight — and the official **5V/3A** PSU
  (`vcgencmd get_throttled` must read `0x0`). The pedal's **LEDs need their
  external 9V rail**: USB-MIDI carries only the LED *frames*, not power, so the LEDs
  stay dark on USB alone even when the MIDI is correct.
- **Connectors.** Pi 4 has 2× **micro-HDMI** → `HDMI-A-1` / `HDMI-A-2`. Set
  `LOOPY_MAIN_OUTPUT` / `LOOPY_WAVE_OUTPUT` and the per-panel `--scale` in
  [`deploy/rpi/pin-displays.sh`](../deploy/rpi/pin-displays.sh). On the **TV**,
  turn **overscan** off ("Just Scan" / 1:1 in the TV's picture menu, or
  `disable_overscan=1` in `config.txt`) or the UI edges are clipped.
- **First-run device setup.** `LOOPY_CONSOLE` hides the transport chrome, so the
  device pickers live in **Settings** (right-click, or press `S`). Bind: (a) the
  **MIDI FOOT CONTROLLER** input, (b) the **PEDAL LINK** output, and (c) the
  **audio interface as both input and output @ 512 frames**. These persist across
  reboots (`tryAutoStartEngine` + hotplug reconnect). **Open question:** confirm
  Settings is reachable in a console build; if it is not, do the first-run bind
  with a **non-console** bundle (omit `--dart-define=LOOPY_CONSOLE=true` — no new
  tooling), then switch back to the console bundle.

### Goal 1 — Dual-display

- **Procedure.** Boot the kiosk; the main UI should land on the monitor and the
  waveform on the TV via `desktop_multi_window` + `pin-displays.sh`.
- **Functional-smoke pass:** both outputs render; the mapping holds across **≥3
  reboots**; unplugging the TV shows the single-display / waveform-failed banner
  (not a dark half-screen).
- **Isolate a failure:** confirm labwc is active; run the bundle by hand under a
  manual labwc session; check that the three window plugins (`desktop_multi_window`,
  `window_manager`, `screen_retriever`) load.

### Goal 2 — USB-MIDI pedal

- **Procedure.** Input arrives as **CC 80/81/82/83 on track 0**
  (`MidiControllerSource`); LED-out runs `pedal_repository` →
  `NativePedalTransport` → `MidiOutClient`
  (see [MIDI_FOOT_CONTROLLER.md](MIDI_FOOT_CONTROLLER.md)).
- **Functional-smoke pass:** the pedal is auto-selected on each boot; every switch
  fires the correct action (**one stomp = one action**, no double-fire); the LEDs
  track engine state; a hotplug re-attaches without an engine restart.
- **Isolate a failure:** `aconnect -l` / `amidi -l` to confirm the OS sees the
  device; confirm **PEDAL LINK** is bound and the **9V rail is on**; the on-screen
  faceplate mirrors the intended LEDs, which isolates firmware from app.

### Goal 3 — Focusrite audio

- **Procedure.** Select the Focusrite as **both input and output @ 512 frames**.
- **Functional-smoke pass:** the input is **heard, not silent** (proves the JACK
  backend + port pinning); a loop records, overdubs, and plays back **xrun-free**;
  the channels land on the real interface (not a "Monitor of …" source).
- **Isolate a failure:** `pw-record` / `arecord` to prove capture outside Loopy;
  verify `pipewire-jack` is installed and that Loopy selected the JACK backend.

### VST3 on the Pi (documented only — no hands-on test this pass)

VST3 is answered on paper, not tested here: the host cross-compiles to `aarch64`;
the ceiling is **`aarch64`-native plugin availability**; plugin editor GUIs need
XWayland (Tier 2 / 3a) or run GUI-less (3b); and Pi 4 headroom is tight. The full
answer is in the brainstorm's *"VST3 plugins on the Pi"* section
([brainstorm](brainstorm/2026-07-22-rpi4b-hardware-validation-brainstorm-doc.md))
and the research doc's **§4.3**
([research](research/2026-07-22-rpi5-embedded-boot-experience-research.md)). A
small `aarch64` plugin spike (find/compile one plugin, host it headless) is a
**follow-up issue**, not part of this pass.

### Results (fill in on hardware)

| Check | Result | Notes (buffer, xruns, reboots, quirks) |
|---|---|---|
| Goal 1 — Dual-display (monitor + TV) | ☐ pass ☐ fail | |
| Goal 2 — USB-MIDI pedal (in + LED out) | ☐ pass ☐ fail | |
| Goal 3 — Focusrite audio (in + out @ 512) | ☐ pass ☐ fail | |
| `aarch64` bundle builds from the Mac | ☐ pass ☐ fail | `deploy/rpi/build/build-arm64-bundle.sh` |
