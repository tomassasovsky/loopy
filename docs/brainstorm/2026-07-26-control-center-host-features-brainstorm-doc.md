---
date: 2026-07-26
topic: control-center-host-features
---

# Control Center Host Features (WiFi / Bluetooth / Brightness)

## What We're Building

Wire the console settings-tray tiles that were stubbed in #302 to real
appliance host controls:

- **WiFi** — full scan / join (PSK) / disconnect / forget / status
- **Bluetooth** — discovery (scan nearby) + broadcasting (discoverable /
  advertise as "Loopy"); no pairing yet
- **Brightness** — tray slider drives the panel and persists across restarts
- **Tuner** — stays "coming soon"

## Why This Approach

The Yocto kiosk image already has `wpa_supplicant`, `systemd-networkd`, and
`bluez5`, but no NetworkManager/connman and no brightness tooling. The OTA
stack already established a pattern: Flutter → injectable `*Env` →
`Process.run` on a `/usr/bin/loopy-*-ctl` helper shipped by `loopy-bundle`.

Three approaches were considered:

- **A — NetworkManager + Flutter plugins.** Needs `meta-networking`, conflicts
  with networkd, and pulls a large stack for a single-app appliance.
- **B — Direct DBus from Dart.** No existing DBus usage in the app; heavier
  test surface than shell helpers.
- **C — Thin `loopy-*-ctl` helpers (mirror OTA).** Reuses the proven
  privilege/test boundary; JSON stdout for structured results.

Landed on **C**. WiFi wraps `wpa_cli`; Bluetooth wraps `bluetoothctl`;
brightness wraps `ddcutil` (DDC/CI VCP 0x10) with an `isSupported` gate so
desktop and non-capable panels no-op safely.

## Key Decisions

- No NetworkManager / connman — stay on wpa_supplicant + networkd.
- Brightness via ddcutil, not wlr-randr (appliance compositor is weston) and
  not `/sys/class/backlight` (HDMI panels usually lack it).
- Tray WiFi/BT tiles navigate to full pages (like Signal), closing the tray
  first; Tuner keeps the stub dialog.
- Persist brightness in `SettingsRepository` (`ui.brightness`).
- Autonomy: `blocked-verify` — CI covers fakes; radios/panel need hardware.

## Open Questions

- Does the shipping 15.6in panel answer DDC/CI VCP 0x10? If not, a gamma
  fallback is a follow-up without blocking WiFi/BT.
