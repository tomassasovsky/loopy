# Loopy appliance: build the Pi 4 kernel with full CONFIG_PREEMPT for low-latency
# live looping. linux-raspberrypi is a kernel-yocto (kmeta) recipe, so a plain
# .cfg fragment in SRC_URI is merged into the config automatically (same mechanism
# as the stock powersave.cfg). We wanted PREEMPT_RT, but arm64 on this 6.6 kernel
# does not select ARCH_SUPPORTS_RT (that lands ~6.12), so PREEMPT_RT is not
# selectable and CONFIG_PREEMPT is the best model here — see preempt.cfg.
#
# Applies to PN=linux-raspberrypi (raspberrypi4-64); the 32-bit v7 recipe has a
# different PN and is untouched.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://preempt.cfg"
