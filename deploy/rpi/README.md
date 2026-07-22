# Loopy floor-console kiosk deployment (Raspberry Pi 5)

Boots the Pi straight into Loopy full-screen across both displays — 16″ main UI,
7″ waveform — under the **labwc** Wayland compositor chosen in Part 1. No
keyboard or mouse.

> **Status: unverified on hardware.** These units and scripts are written from
> the Part 5 plan but have not been brought up on a real Pi 5 + panels. The real
> acceptance gates — cold boot to the right panels, display pinning stable across
> ≥5 reboots, and usable per-panel scale — must be checked on hardware. See
> [`docs/RUNNING_ON_RPI.md`](../../docs/RUNNING_ON_RPI.md).

## Files

| File | Goes to | Purpose |
|---|---|---|
| `loopy-kiosk.service` | `/etc/systemd/system/` | Boots the kiosk on tty1, respawns on crash |
| `boot-integrity-check.sh` | (unit `ExecStartPre=+`, root) | fsck + mount the writable data partition |
| `start-kiosk.sh` | (unit `ExecStart`) | Execs labwc, or shows the "needs attention" screen |
| `compositor/labwc/autostart` | `~/.config/labwc/autostart` | Pins displays, then launches the app |
| `compositor/labwc/rc.xml` | `~/.config/labwc/rc.xml` | Chromeless, maximized, no kill chord |
| `pin-displays.sh` | (run from autostart) | Deterministic output pinning by name |
| `overlayfs/README.md` | — | Read-only root + writable data partition setup |

## Install

1. Build the release bundle on the Pi with **console/kiosk mode** on:
   ```bash
   flutter build linux --release --dart-define=LOOPY_CONSOLE=true
   ```
   `LOOPY_CONSOLE=true` hides the on-screen tracks toolbar (the foot pedals
   drive transport/mode/clear) and tightens the layout for the fixed 16″ panel
   — see [`lib/common/console_mode.dart`](../../lib/common/console_mode.dart). Omit
   the define for a normal desktop build. (The `build-linux-arm64` CI job guards
   that this compiles for arm64.)
2. Enable the labwc Wayland compositor (Pi OS default on Pi 5; confirm with
   `wlr-randr`, which must list outputs — see `docs/RUNNING_ON_RPI.md`).
3. Copy the config:
   ```bash
   mkdir -p ~/.config/labwc
   cp deploy/rpi/compositor/labwc/* ~/.config/labwc/
   chmod +x deploy/rpi/pin-displays.sh \
            deploy/rpi/start-kiosk.sh \
            deploy/rpi/boot-integrity-check.sh
   sudo cp deploy/rpi/loopy-kiosk.service /etc/systemd/system/
   sudo systemctl enable loopy-kiosk.service
   ```
   For power-cut resilience (read-only root + a writable data partition that the
   boot integrity check fscks and mounts), follow
   [`overlayfs/README.md`](overlayfs/README.md).
4. **Edit `pin-displays.sh`** for your wiring: run `wlr-randr` to get the real
   connector names (e.g. `HDMI-A-1`, `HDMI-A-2`, or `DSI-1`) and set
   `LOOPY_MAIN_OUTPUT` / `LOOPY_WAVE_OUTPUT` and the per-panel scales.
5. Reboot. The unit starts labwc, which pins the displays and launches Loopy.

## Display mapping & fallbacks

- **Pinning** is by connector name in `pin-displays.sh`, so the 16″ and 7″ never
  swap. The app's waveform second window lands on the secondary output; verify
  the actual window→output placement on hardware and adjust positions if needed.
- **Second-window failure is surfaced**, not silent: if the waveform window does
  not become ready, the app shows an operator-visible banner
  (`app_waveformWindowFailed_banner`).
- **Single display**: if only one display is connected, the app skips the
  waveform window and shows a notice (`app_singleDisplay_banner`) instead of a
  half-blank console. The Pi entrypoint wires the real display count
  ([`run_loopy.dart`](../../lib/app/run_loopy.dart)).
- **Per-display scale** is set with `wlr-randr --scale` in `pin-displays.sh`.
  Final values depend on the Part-6 HDMI-vs-DSI panel choice; tune on hardware.
