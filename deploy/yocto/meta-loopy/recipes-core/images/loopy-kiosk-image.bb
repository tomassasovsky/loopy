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
    "
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
