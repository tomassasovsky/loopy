SUMMARY = "Segno floor-console kiosk image: weston + the prebuilt Flutter GTK bundle"
LICENSE = "MIT"

# Start from the stock Wayland image (weston + weston-init + GTK3 already present),
# then add our bundle and its runtime deps. See docs/plan Tier 3a §Phase 2.
#
# Note what is NOT here: meta-rauc's rauc-mark-good. Its unit is condition-gated
# on a `rauc.slot` kernel argument that the Pi tryboot backend never sets, so it
# was skipped on every boot and every update silently rolled back. segno-bundle
# ships segno-mark-good.service in its place, behind a health gate (#307).
require recipes-graphics/images/core-image-weston.bb

IMAGE_INSTALL:append = " \
    segno-bundle \
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
    plymouth-segno-theme \
    rauc \
    rauc-conf \
    rauc-rpi-backend \
    raspi-utils \
    dtc \
    ddcutil \
    networkmanager-nmcli \
    networkmanager-wifi \
    bluez5 \
    "
# tryboot-cmdline.bbclass edits cmdline.txt inside the .wic (mtools) and regenerates
# the bmap (bmaptool) — both are native build tools its task needs.
do_update_tryboot_cmdline[depends] += "mtools-native:do_populate_sysroot bmaptool-native:do_populate_sysroot"
# plymouth boot splash (segno mark, breathe + shimmer) covers the black screen from
# power-on until weston/segno render. plymouth-segno-theme sets itself active.
# Keep psplash (the other splash, pulled in by the base image) out so the two don't
# fight over the framebuffer — plymouth owns the splash.
IMAGE_INSTALL:remove = "psplash psplash-raspberrypi"
BAD_RECOMMENDATIONS += "psplash psplash-raspberrypi"
PACKAGE_EXCLUDE += "psplash psplash-raspberrypi"
# Audio: DIRECT ALSA, no PipeWire/JACK/Pulse. This is a single-app appliance that
# owns the sound card, so the engine drives ALSA directly (SEGNO_ALSA_ONLY, set by
# segno-kiosk-launch) for the lowest latency and zero IPC — the textbook mono-app
# embedded-audio path. The ALSA-duplex reconfigure deadlock that originally pushed
# us to PipeWire is fixed in the engine (ma_device_stop before uninit), so runtime
# sample-rate / buffer changes work on raw ALSA. No pipewire/wireplumber packages,
# no session daemons, no plugin clutter in the device list. Low-latency tuning is
# system-level (performance governor + threadirqs via CMDLINE, PREEMPT_RT kernel
# on 6.12, SCHED_FIFO audio thread + rtirq) rather than a sound server.

# RAUC A/B (tryboot) SD layout: boot selector + bootA/bootB + rootA/rootB + data
# (Phase 1, #303). See wic/segno-tryboot.wks. `wic` = the flashable SD image;
# `ext4` = the bare rootfs artifact the .raucb bundle packages (RAUC_SLOT_rootfs).
WKS_FILE = "segno-tryboot.wks"
IMAGE_FSTYPES = "wic ext4"

# Rewrite each boot slot's cmdline.txt root= inside the .wic after do_image_wic
# (bootA->rootA p5, bootB->rootB p6) — see classes/tryboot-cmdline.bbclass.
# NOTE: recipe-level `inherit` (lowercase); `INHERIT +=` only works at conf level.
inherit tryboot-cmdline

# Headroom for the kernel & modules on the rootfs. User/session data lives on /data.
IMAGE_ROOTFS_EXTRA_SPACE = "1048576"
# xdg-user-dirs provides the `xdg-user-dir` binary. Flutter's path_provider shells
# out to it for getApplicationDocumentsDirectory; without it the app throws
# MissingPlatformDirectoryException on startup. The launcher seeds a user-dirs.dirs
# so it resolves ~/Documents (see segno-kiosk-launch). Validated on device.
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

# NetworkManager owns eth0 + wlan*. Mask systemd-networkd so the two managers
# never fight over the same interfaces (SSH still comes up via NM DHCP).
segno_mask_networkd() {
    # Mask into /etc so it wins over /lib unit files without deleting packages.
    install -d ${IMAGE_ROOTFS}/etc/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd.service
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd.socket
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd-wait-online.service
}
ROOTFS_POSTPROCESS_COMMAND += "segno_mask_networkd; "

# ALSA-only by design (no PipeWire/JACK): the engine falls straight to ALSA, so no
# pw-jack shim is needed (cleaner than the Pi OS / Tier 2 path). See plan §Phase 3.

# Spike convenience: root login (empty password) + SSH for bring-up debugging.
# walnascar dropped the `debug-tweaks` umbrella feature, so name its parts. Drop
# all of this for anything resembling production.
IMAGE_FEATURES:append = " allow-empty-password allow-root-login empty-root-password post-install-logging ssh-server-dropbear"
