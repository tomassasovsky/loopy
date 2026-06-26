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
# Set LOOPY_DATA_DEV to the data partition (default /dev/mmcblk0p3); it must NOT
# be in the boot-time fstab automount (this script mounts it after fsck).
#
# UNVERIFIED on hardware — confirm the device node + mount flow on a real Pi.
set -u

DATA_DEV="${LOOPY_DATA_DEV:-/dev/mmcblk0p3}"
DATA_MNT="${LOOPY_DATA_MNT:-/var/lib/loopy}"
BAD_MARKER="${LOOPY_BAD_MARKER:-/run/loopy-data-unhealthy}"

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
