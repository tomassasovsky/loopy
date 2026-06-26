#!/bin/sh
# Pin the floor console's two displays deterministically by connector name, so
# the 16" main-UI panel and the 7" waveform panel never swap across reboots
# (the output-naming race called out in the Part 5 plan). Uses wlr-randr, which
# the Part-1 compositor (labwc, wlroots-based) exposes via
# wlr-output-management.
#
# Connector names depend on wiring; list them with `wlr-randr`. The 7" may be
# HDMI-A-2 (HDMI) or DSI-1 (the official DSI panel — decided in the Part-6
# HDMI-vs-DSI spike). EDIT the names/resolutions/scales below to match the unit.
#
# UNVERIFIED on hardware — confirm connector names and that the mapping holds
# across >=5 reboots (the real Part 5 acceptance gate).
set -eu

MAIN="${LOOPY_MAIN_OUTPUT:-HDMI-A-1}"   # 16" main UI (BigPictureView)
WAVE="${LOOPY_WAVE_OUTPUT:-HDMI-A-2}"   # 7" waveform window

# 16" ~1080p at scale 1; sits at the origin so it's the primary.
wlr-randr --output "$MAIN" --on --pos 0,0 --scale "${LOOPY_MAIN_SCALE:-1}" \
  || echo "pin-displays: could not configure $MAIN" >&2

# 7" placed to the right of the 16". Scale up the low-DPI panel so the waveform
# is legible (800x480 DSI -> scale 0.5; a 1080p 7" HDMI -> scale ~1.5). Tune per
# panel after the Part-6 spike.
wlr-randr --output "$WAVE" --on --pos 1920,0 --scale "${LOOPY_WAVE_SCALE:-1}" \
  || echo "pin-displays: could not configure $WAVE (single-display?)" >&2
