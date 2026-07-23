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
    "

# ALSA-only by design (no PipeWire/JACK): the engine falls straight to ALSA, so no
# pw-jack shim is needed (cleaner than the Pi OS / Tier 2 path). See plan §Phase 3.

# Spike convenience: root autologin on the console for bring-up debugging. Drop
# for anything resembling production.
IMAGE_FEATURES:append = " debug-tweaks"
