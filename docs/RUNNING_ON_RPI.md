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
