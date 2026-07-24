# Loopy floor-console audio (Tier 3a): the engine prefers the JACK backend on
# Linux and gets tunable, low-latency, cleanly-reconfigurable audio through it
# (the raw-ALSA/miniaudio path deadlocks on a device rate change). Build
# PipeWire's JACK reimplementation (pw-jack + a libjack.so.0 replacement under
# ${libdir}/pipewire-0.3/jack) instead of importing real libjack — the launcher
# runs the app under pw-jack so miniaudio's dlopen("libjack.so.0") lands on
# PipeWire. `jack` and `pipewire-jack` PACKAGECONFIGs are mutually exclusive.
PACKAGECONFIG:remove = "jack"
PACKAGECONFIG:append = " pipewire-jack"

# Audio-only appliance: drop the camera/video SPA plugins. On the Pi 4 the
# v4l2/libcamera monitors probe ~14 bcm2835 video nodes + libcamera, and PipeWire
# SEGV'd intermittently on this device (status=11) with them present; moving them
# aside on-device let pipewire survive markedly longer. Not needed for audio.
PACKAGECONFIG:remove = "v4l2 libcamera gstreamer"

# We run PipeWire + WirePlumber as our own services sharing the weston
# XDG_RUNTIME_DIR (/run/user/1000) so the app (also there) finds pipewire-0
# next to wayland-1. Disable the packaged pipewire-user/system service so it
# doesn't race our unit.
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

# WIP / BLOCKED-VERIFY: PipeWire is installed on-device and sees the Scarlett
# (default sink+source), and pw-jack + the libjack replacement are in place, but
# `pipewire` SEGVs intermittently on this Yocto/Pi 4 config (prime suspects: the
# missing D-Bus *session* bus that spa.dbus/mod.portal error on, and/or realtime
# setup). Needs a coredump backtrace (gdb on the x86 build host against the target
# core) or module bisection before the JACK audio path can be validated end-to-end
# and the pipewire/wireplumber service units + loopy.service User rewiring landed.
