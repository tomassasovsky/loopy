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

- **GPIO** — the 40-pin header is `/dev/gpiochip0` on the Pi 4, which is exactly
  what `gpio_client` defaults to. (On the Pi 5 the GPIO sits behind the RP1 chip
  and is often `/dev/gpiochip4`, so the Pi 5 may instead need a chip-path
  override — the Pi 4 needs none.)
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
  RP2040 LED driver, GPIO-protection passives, and power.
- **GPIO protection + power/thermal budget + enclosure intent:**
  [`hardware/console/README.md`](../hardware/console/README.md) — 3.3 V input
  protection (series-R + RC + optional clamp; active-low to GND), the per-rail
  power budget, and the active-cooling requirement.

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
- [ ] **Miswire test**: a 5 V touch to each protected GPIO input does not damage
      the pin (per `hardware/console/README.md`).
- [ ] Stompable footswitch panel survives stage-abuse testing.
