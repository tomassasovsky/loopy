---
title: "chore: close-out plan for the open appliance/console backlog"
type: chore
date: 2026-08-02
---

## chore: close-out plan for the open appliance/console backlog

Written after a long session that shipped the pedal firmware OTA end to end and
then discovered a released Control Center branch had never been merged. The
backlog is not 30 independent items — it is **four clusters, three of which are
gated on a single thing each.**

## The keystone: land #450

`feat/control-center-host-features` was released to the console and never
merged. While it sits unmerged, master ships a console with no Wi-Fi UI, and at
least five open issues describe problems that branch already fixed.

**Landing #450 closes or resolves:** #348 (Control Center itself), #309 (SSH
host keys per slot — `loopy-ssh-persist`), the Wi-Fi half of #432, and makes
#451 a small follow-up rather than a design question.

**It is blocked on exactly one decision:** master's tests assert
`app_deviceLost_banner` / `app_midiLost_banner`; that branch converted those
notifications to toasts. Both are defensible; they cannot both be true.

- **Toasts win** → delete/rewrite master's two banner tests, keep the toast
  rewrite. Smaller diff, matches the newer UI direction.
- **Banners win** → restore the banner widgets and keep toasts for transient
  notices only. More work, but banners are arguably right for a *persistent*
  condition like "your interface is unplugged", which a toast hides after 3s.

Recommendation: **banners for persistent conditions, toasts for transient
events.** The distinction is real, and "device lost" is not an event.

Everything else in #450 is verified: analyze clean, format clean, flash-pedal
28/28, pedal-firmware CI job intact, `loopy-update-ctl` carrying both
`flash-pedal` and `reconcile-staged`.

## Cluster 2 — hardware validation, no code needed

These need a device and an A/B update, not a keyboard. Batch them into ONE
bench session on the release that follows #450:

| Issue | What to do |
|---|---|
| #432 | Join Wi-Fi, reboot, then take an OS update. The update half has never been proven. |
| #451 | Same for Bluetooth — will look fine after a reboot and fail after an update. Needs the fix first. |
| #309 | Confirm the SSH host key survives an update (no MITM warning). |
| #307 | Confirm `rauc-mark-good` auto-commits after tryboot. |
| #402 | FX interaction mode on the physical pedal. |
| #417/#419 | FX v3 part 9 soak. `blocked-verify`, so do NOT merge #419 unattended. |

Doing these one at a time costs an OS update each (~15 min on the warm
runner). Doing them together costs one.

## Cluster 3 — needs a direction call from you

Each is small once decided and stuck until then.

- **#444** — the flasher is permanently one update behind, because the flash
  runs from the *running* image. Recommend option 1: a post-reboot oneshot,
  which also closes the retry gap.
- **#442** — console UI redesign. Brainstorm is landed; next step is `/plan`.
- **#389** — session load never writes chains back to settings.
- **#405** — immediate-finalize primitive for FX-mode entry.
- **#369 / #372** — LED pill widening, virtual sliders.
- **#438** — persistent journal + coredumps. Note this is *not* a drop-in:
  journald starts long before `/data` mounts.

## Cluster 4 — the stacked CAD chain

#366 → #358/#359 → #368 → #376, plus #396/#397. These are **stacked** (#376's
base is #368's branch) and each touches ~27 binary STEP/DXF/PDF files.

Do not squash-merge them in arbitrary order: squashing a parent breaks the
child's merge-ref, and git will happily *text*-merge binary CAD. Land them
oldest-first, rebasing each child after its parent lands, and open each
resulting STEP once before merging the next.

## Already done, safe to close

- **#435** — the segno mirror now serves `.hex` (verified 200, checksum matches
  the manifest). Closeable once someone confirms the fix is deployed.
- **#440** — merged (#441).

## Suggested order

1. Decide banners vs toasts → finish #450 → merge.
2. Cut one release; run the whole of cluster 2 against it in one sitting.
3. Fix #451 and #444 (both small, both understood).
4. Take #442 to `/plan` when there is appetite for a redesign.
5. Land the CAD chain oldest-first, separately from everything above.
