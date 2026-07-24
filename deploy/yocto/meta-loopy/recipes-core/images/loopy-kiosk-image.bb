SUMMARY = "Loopy floor-console kiosk image: weston + the prebuilt Flutter GTK bundle"
LICENSE = "MIT"

# Start from the stock Wayland image (weston + weston-init + GTK3 already present),
# then add our bundle and its runtime deps. See docs/plan Tier 3a §Phase 2.
require recipes-graphics/images/core-image-weston.bb

IMAGE_INSTALL:append = " \
    loopy-bundle \
    gtk+3 \
    mesa \
    alsa-lib \
    alsa-utils \
    alsa-plugins \
    util-linux-chrt \
    gsettings-desktop-schemas \
    seatd \
    xdg-user-dirs \
    plymouth \
    plymouth-loopy-theme \
    "
# plymouth boot splash (segno mark, breathe + shimmer) covers the black screen from
# power-on until weston/loopy render. plymouth-loopy-theme sets itself active.
# Keep psplash (the other splash, pulled in by the base image) out so the two don't
# fight over the framebuffer — plymouth owns the splash.
IMAGE_INSTALL:remove = "psplash psplash-raspberrypi"
BAD_RECOMMENDATIONS += "psplash psplash-raspberrypi"
PACKAGE_EXCLUDE += "psplash psplash-raspberrypi"
# Audio: DIRECT ALSA, no PipeWire/JACK/Pulse. This is a single-app appliance that
# owns the sound card, so the engine drives ALSA directly (LOOPY_ALSA_ONLY, set by
# loopy-kiosk-launch) for the lowest latency and zero IPC — the textbook mono-app
# embedded-audio path. The ALSA-duplex reconfigure deadlock that originally pushed
# us to PipeWire is fixed in the engine (ma_device_stop before uninit), so runtime
# sample-rate / buffer changes work on raw ALSA. No pipewire/wireplumber packages,
# no session daemons, no plugin clutter in the device list. Low-latency tuning is
# system-level (performance governor + threadirqs via CMDLINE, full-CONFIG_PREEMPT
# kernel, SCHED_FIFO audio thread + rtirq) rather than a sound server. True
# PREEMPT_RT needs a 6.12 kernel (arm64 ARCH_SUPPORTS_RT) — tracked separately.

# Headroom for the app/session data + the kernel & modules.
IMAGE_ROOTFS_EXTRA_SPACE = "1048576"
# xdg-user-dirs provides the `xdg-user-dir` binary. Flutter's path_provider shells
# out to it for getApplicationDocumentsDirectory; without it the app throws
# MissingPlatformDirectoryException on startup. The launcher seeds a user-dirs.dirs
# so it resolves ~/Documents (see loopy-kiosk-launch). Validated on device.
# gsettings-desktop-schemas provides the schema the embedder's settings lookup
# needs (silences the G_IS_SETTINGS warning); the dconf persistent backend lives
# in meta-gnome (not included) — not worth a whole layer for cosmetic polish.
# alsa-plugins provides the dmix/dsnoop slaves the bare ALSA config references.
#
# seatd = the seat provider weston's libseat needs to open input devices. On this
# minimal image weston has no active logind session and no seatd → keyboard/mouse
# dead. Ship + enable seatd and point weston at it. NEEDS ON-DEVICE VALIDATION:
# weston must reach /run/seatd.sock (the weston user in seatd's group, or seatd
# started with a shared group) and run with LIBSEAT_BACKEND=seatd.
SYSTEMD_AUTO_ENABLE:pn-seatd = "enable"

# ALSA-only by design (no PipeWire/JACK): the engine falls straight to ALSA, so no
# pw-jack shim is needed (cleaner than the Pi OS / Tier 2 path). See plan §Phase 3.

# Spike convenience: root login (empty password) + SSH for bring-up debugging.
# walnascar dropped the `debug-tweaks` umbrella feature, so name its parts. Drop
# all of this for anything resembling production.
IMAGE_FEATURES:append = " allow-empty-password allow-root-login empty-root-password post-install-logging ssh-server-dropbear"
