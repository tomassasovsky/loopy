#!/bin/sh
# Kiosk entry point (systemd ExecStart, runs as the kiosk user). The root
# ExecStartPre (boot-integrity-check.sh) has already fscked + mounted the
# writable data partition, or dropped the unhealthy marker if the card is
# damaged.
#
# Clean check -> exec labwc (whose autostart pins the displays and launches
# Loopy). Damaged card -> show a "needs attention" screen on the console and
# hold, so a power-cut-corrupted card boots to a visible message instead of a
# black display, and the unit does not respawn-loop.
#
# UNVERIFIED on hardware — bring up on a real Pi + card before relying on it.
set -u

BAD_MARKER="${LOOPY_BAD_MARKER:-/run/loopy-data-unhealthy}"

if [ ! -f "$BAD_MARKER" ]; then
  exec /usr/bin/labwc
fi

cat >/dev/tty1 <<'MSG'

  Loopy — storage needs attention

  The writable storage partition is damaged and could not be repaired
  automatically. Connect a keyboard/HDMI and run an fsck, or re-flash the
  data partition. The looper will not start until storage is healthy.

MSG
# Keep the message on screen; the systemd Restart= would otherwise clear it.
exec sleep infinity
