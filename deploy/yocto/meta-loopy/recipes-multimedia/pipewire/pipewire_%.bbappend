# Loopy floor-console audio (Tier 3a): the engine prefers the JACK backend on
# Linux and gets tunable, low-latency, cleanly-reconfigurable audio through it
# (the raw-ALSA/miniaudio path deadlocks on a device rate change). Build
# PipeWire's JACK reimplementation (pw-jack + a libjack.so.0 replacement under
# ${libdir}/pipewire-0.3/jack) instead of importing real libjack — the launcher
# runs the app under pw-jack so miniaudio's dlopen("libjack.so.0") lands on
# PipeWire. `jack` and `pipewire-jack` PACKAGECONFIGs are mutually exclusive.
PACKAGECONFIG:remove = "jack"
PACKAGECONFIG:append = " pipewire-jack"

# (We leave the camera/video SPA plugins in: they're unused on this audio
# appliance but harmless, and dropping libcamera also drops libdrm which the still-
# enabled vulkan SPA plugin needs -> meson configure fails. Not worth the cascade;
# the rootfs has headroom. The crash that mattered was ALSA-MIDI, fixed in the
# WirePlumber drop-in, not here.)

# We run PipeWire + WirePlumber as our own services (loopy-pipewire.service /
# loopy-wireplumber.service, shipped by loopy-bundle) sharing the weston
# XDG_RUNTIME_DIR (/run/user/1000) so the app finds pipewire-0 next to wayland-1.
# Disable the packaged pipewire.service so it doesn't race our unit.
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

# NOTE: pipewire SEGV'd intermittently on this Pi 4 until the ALSA-MIDI monitor was
# disabled — its seq probe crashed libasound (snd_seq_event_retrieve_buffer <-
# alsa_seq_on_sys, found via addr2line). That fix lives in the WirePlumber drop-in
# 50-loopy-no-midi.conf (loopy-bundle), not here. With it, the JACK audio path is
# stable across reboots (validated on a Pi 4B).
