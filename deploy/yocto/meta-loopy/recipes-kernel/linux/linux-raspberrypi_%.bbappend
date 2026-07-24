# Loopy appliance: build the Pi 4 kernel with the PREEMPT_RT real-time preemption
# model for glitch-free low-latency live looping. linux-raspberrypi is a
# kernel-yocto (kmeta) recipe, so a plain .cfg fragment in SRC_URI is merged into
# the config automatically (same mechanism as the stock powersave.cfg). rt.cfg
# selects CONFIG_PREEMPT_RT (and unsets the other preemption-model choices so the
# Kconfig `choice` resolves cleanly). See docs/plan Tier 3a audio tuning.
#
# Applies to PN=linux-raspberrypi (raspberrypi4-64); the 32-bit v7 recipe has a
# different PN and is untouched.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://rt.cfg"
