# Read-only root + writable data partition (power-cut resilience)

A stompable performance unit will get its power cut mid-set. A normal read-write
SD root corrupts under that; the fix is a **read-only root filesystem** with all
mutable state confined to a small, clearly-scoped **writable data partition** so
a yanked cable can never damage the OS.

> Durability target is **"no SD corruption"**, not "no lost loop." A read-only
> root protects the OS, not unsaved musical work — live-loop checkpoint/restore
> is a separate, product-wide concern tracked outside this Pi effort. See the
> Part 6 plan scope note.

> **Status: unverified on hardware.** Bring up and run the power-cut stress test
> (below) on a real Pi + card before relying on this.

## Layout

| Partition | Mount | Mode | Contents |
|---|---|---|---|
| `mmcblk0p1` | `/boot/firmware` | ro | firmware + kernel + `cmdline.txt` |
| `mmcblk0p2` | `/` | **ro (overlay)** | OS + the Loopy bundle |
| `mmcblk0p3` | `/var/lib/loopy` | rw | app settings + saved sessions |

The app must write its settings/sessions onto the writable partition, not the
read-only root. Point the XDG data dir at it for the kiosk user, e.g. in the
kiosk environment:

```sh
export XDG_DATA_HOME=/var/lib/loopy/share
export XDG_CONFIG_HOME=/var/lib/loopy/config
```

(`SharedPreferences` and the session directory resolve under these via
`path_provider`.)

## Enabling the read-only overlay root

Raspberry Pi OS ships an overlay-root toggle that keeps `/` read-only and holds
writes in a tmpfs overlay (discarded on reboot — exactly what we want for the
OS):

```bash
sudo raspi-config nonint enable_overlayfs   # Performance Options → Overlay FS
# or interactively: sudo raspi-config → Performance Options → Overlay File System
```

Then create + format the separate writable data partition and add it to
`/etc/fstab` **without** an automount that races the boot integrity check (the
check mounts it after fsck):

```fstab
# /dev/mmcblk0p3 is mounted by deploy/rpi/boot-integrity-check.sh after fsck.
/dev/mmcblk0p3  /var/lib/loopy  ext4  noauto,noatime  0  0
```

`/boot/firmware` should also be remounted read-only once configured.

## Power-cut stress test (the real acceptance gate)

Read-only root is only proven by abuse. Run **≥20 hard power-cuts** mid-session
and confirm the unit boots cleanly every time with no SD corruption:

```text
for i in 1..20:
  - power on, wait for the looper, start recording/overdubbing a loop
  - cut mains power (no shutdown) after a few seconds
  - power on again
  - confirm: boots to the looper, no fsck failure screen, OS intact
```

Record the result (pass/fail per cycle, any fsck repairs) in
[`docs/RUNNING_ON_RPI.md`](../../../docs/RUNNING_ON_RPI.md).

## Safe shutdown

With a read-only root, **cutting power is safe for the OS** — nothing is mid-write
on `/`. The writable data partition is mounted with journaling and fsck'd on the
next boot, so an interrupted save self-heals. For a graceful stop (e.g. a wired
power button), `sudo systemctl poweroff` unmounts `/var/lib/loopy` cleanly; wire
a momentary button to `dtoverlay=gpio-shutdown` in `config.txt` if a physical
power-off is wanted.
