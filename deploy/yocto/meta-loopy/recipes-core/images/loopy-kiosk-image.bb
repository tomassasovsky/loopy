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
    dconf \
    "
# gsettings-desktop-schemas + dconf back the embedder's GNOME settings lookups
# (silences the G_IS_SETTINGS warning); alsa-plugins provides the dmix/dsnoop
# slaves the bare ALSA config references.

# ALSA-only by design (no PipeWire/JACK): the engine falls straight to ALSA, so no
# pw-jack shim is needed (cleaner than the Pi OS / Tier 2 path). See plan §Phase 3.

# Spike convenience: root login (empty password) + SSH for bring-up debugging.
# walnascar dropped the `debug-tweaks` umbrella feature, so name its parts. Drop
# all of this for anything resembling production.
IMAGE_FEATURES:append = " allow-empty-password allow-root-login empty-root-password post-install-logging ssh-server-dropbear"
