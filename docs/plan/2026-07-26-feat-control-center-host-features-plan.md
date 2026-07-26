---
title: Control Center Host Features
type: feat
date: 2026-07-26
---

## Control Center Host Features - Standard

Closes #348

## Overview

Wire the settings-tray WiFi, Bluetooth, and brightness tiles to real appliance
host controls (Yocto helpers + layered Flutter backends). Tuner stays stubbed.

| Feature | This round | Deferred |
|---------|------------|----------|
| WiFi | Scan, join (PSK), disconnect, forget, status, radio on/off | Hotspot, enterprise EAP |
| Bluetooth | Scan + power/discoverable/advertise | Pairing, GATT, sidecar |
| Brightness | ddcutil + persist | Gamma fallback if DDC fails |

## Architecture (VGV layered)

```text
Presentation (lib/)     → Cubits / tray panels / pages
Business logic (lib/)   → WifiCubit, BluetoothCubit, SettingsTrayCubit
Repository (packages/)  → wifi_repository, bluetooth_repository
Data (packages/)        → wifi_client, bluetooth_client, brightness_client
Host helpers (Yocto)    → /usr/bin/loopy-{wifi,bt,brightness}-ctl
```

- `wifi_client` / `bluetooth_client` / `brightness_client` — `Process.run` +
  JSON parse only (no Flutter)
- `wifi_repository` / `bluetooth_repository` — thin facades; re-export domain
  models from clients
- Brightness persist stays in `SettingsRepository` (`ui.brightness`); apply via
  `BrightnessClient`
- App bootstrap (`run_loopy` → `App`) constructs system clients and provides
  repositories via `RepositoryProvider`

### Control Center UX

- WiFi / Bluetooth **tap** = radio/power toggle; **long-press** = in-tray config
- Config expands inside the open tray (animated destination swap), not a
  full-screen route
- Tile colors are dual-state: accent = on, shared off color = off; destinations
  that cannot be on always use off

## Yocto

- Helpers + `25-wlan.network` (DHCP) in meta-loopy / loopy-bundle
- Verbs: wifi `radio on|off` + `enabled` in status; bt `power on|off`
- `IMAGE_INSTALL:append` — `ddcutil`; RDEPENDS on wpa-supplicant / bluez5

## Verification

- **CI:** analyze + unit/widget tests with fake clients
- **On device:** checklist in `docs/RUNNING_ON_RPI.md` (Control Center section)

## Non-goals

Tuner; BT pairing; NetworkManager; labwc/wlr-randr brightness path.
