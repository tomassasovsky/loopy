#!/bin/sh
# Boot-time integrity check for the console's writable data partition (where the
# app's settings + sessions live, separate from the read-only root — see
# deploy/rpi/overlayfs/README.md). Runs as root from the kiosk unit's
# `ExecStartPre=+` so it can fsck and mount.
#
# A non-interactive fsck repairs a partition left dirty by a power-cut. On
# success it mounts the partition and clears the unhealthy marker. On an
# unrecoverable partition it drops a marker (LOOPY_BAD_MARKER) and still exits 0
# so the unit proceeds to start-kiosk.sh, which shows the "needs attention"
# screen rather than respawn-looping.
#
# The check is OPT-IN: it only applies when the overlayfs data partition is in
# use. Set LOOPY_DATA_DEV to that partition (the overlayfs default is
# /dev/mmcblk0p3) to enable it; it must NOT be in the boot-time fstab automount
# (this script mounts it after fsck). On a stock single-partition SD card — no
# LOOPY_DATA_DEV and no p3 — there is nothing to check and the app boots normally.
#
# UNVERIFIED on hardware — confirm the device node + mount flow on a real Pi.
set -u

DATA_MNT="${LOOPY_DATA_MNT:-/var/lib/loopy}"
BAD_MARKER="${LOOPY_BAD_MARKER:-/run/loopy-data-unhealthy}"

# Not configured (LOOPY_DATA_DEV unset) and no default partition present → a plain
# SD install without the overlayfs setup. Skip cleanly so the kiosk still starts.
if [ -z "${LOOPY_DATA_DEV+x}" ] && [ ! -b /dev/mmcblk0p3 ]; then
  echo "boot-integrity-check: no data partition configured; skipping (set LOOPY_DATA_DEV to enable)"
  rm -f "$BAD_MARKER"
  exit 0
fi

DATA_DEV="${LOOPY_DATA_DEV:-/dev/mmcblk0p3}"

fail() {
  echo "boot-integrity-check: $1" >&2
  touch "$BAD_MARKER"
  exit 0
}

rm -f "$BAD_MARKER"

[ -b "$DATA_DEV" ] || fail "$DATA_DEV is not a block device"

# -p auto-repairs safe problems; exit codes 0 (clean) and 1 (repaired) are OK,
# 2+ (reboot-required / unrecoverable) is a failure.
fsck -p "$DATA_DEV"
[ "$?" -le 1 ] || fail "fsck of $DATA_DEV failed"

mkdir -p "$DATA_MNT"
mountpoint -q "$DATA_MNT" || mount "$DATA_DEV" "$DATA_MNT" || fail "mount failed"
echo "boot-integrity-check: $DATA_DEV healthy, mounted at $DATA_MNT"
exit 0
