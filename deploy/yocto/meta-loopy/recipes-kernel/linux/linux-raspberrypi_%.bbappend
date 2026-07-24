# Loopy appliance: build the Pi 4 kernel with PREEMPT_RT for glitch-free
# low-latency live looping. linux-raspberrypi is a kernel-yocto (kmeta) recipe, so
# a plain .cfg fragment in SRC_URI is merged into the config automatically (same
# mechanism as the stock powersave.cfg). rt.cfg selects CONFIG_PREEMPT_RT, which is
# selectable on the 6.12 kernel pinned in kas-loopy-rpi4.yml (arm64 gains
# ARCH_SUPPORTS_RT at ~6.12; it is NOT selectable on 6.6).
#
# Applies to PN=linux-raspberrypi (raspberrypi4-64); the 32-bit v7 recipe has a
# different PN and is untouched.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://rt.cfg"
