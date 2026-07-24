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
    gsettings-desktop-schemas \
    seatd \
    xdg-user-dirs \
    pipewire \
    pipewire-jack \
    pipewire-tools \
    wireplumber \
    plymouth \
    plymouth-loopy-theme \
    "
# plymouth boot splash (segno mark, breathe + shimmer) covers the black screen from
# power-on until weston/loopy render. plymouth-loopy-theme sets itself active.
# PipeWire audio stack: the engine prefers JACK on Linux and runs cleanly on it
# (tunable quantum, no ALSA-duplex reconfigure deadlock). pipewire-jack gives
# pw-jack + the libjack replacement; pipewire-tools gives pw-metadata (the engine
# forces the graph quantum through it — without it the buffer selector does
# nothing). wireplumber is the session manager. The pipewire bbappend switches
# jack->pipewire-jack and drops the camera/video plugins. Custom root services +
# WirePlumber drop-ins ship with loopy-bundle. Validated end-to-end on a Pi 4B.

# The base image was already ~590MB and 100% full once PipeWire was added on-
# device; give the rootfs real headroom (pipewire ~100MB + app/session data).
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
