SUMMARY = "Prebuilt Loopy Flutter GTK bundle (installed as-is; NOT built from source)"
DESCRIPTION = "Installs the exact aarch64 Flutter GTK bundle produced by \
deploy/rpi/build/build-arm64-bundle.sh into /opt/loopy, plus a Wayland launcher \
and a systemd unit that runs it under weston. See docs/plan Tier 3a §Phase 2."
# CLOSED: a prebuilt binary we install verbatim — no in-tree license file to
# checksum here (the app's licensing lives in the main repo, not this recipe).
LICENSE = "CLOSED"

# Path to the prebuilt bundle dir (contains 'loopy', libflutter_linux_gtk.so,
# libloopy_engine.so, data/). Defaults to deploy/yocto/prebuilt/bundle relative to
# this recipe (resolves inside the build container regardless of mount point);
# override via LOOPY_BUNDLE_DIR in kas/local.conf to point elsewhere.
LOOPY_BUNDLE_DIR ?= "${THISDIR}/../../../prebuilt/bundle"

# Semver (e.g. "0.2.0" or "0.2.0-experimental.42") stamped into
# /etc/loopy/build-version; the OTA client compares the channel manifest's
# version against it. CI sets LOOPY_BUILD_VERSION per release.
LOOPY_BUILD_VERSION ?= "0.0.0"

# Channel stamped into /etc/loopy/update-channel (`experimental` / `production`).
# CI sets this to match the release channel so experimental images don't
# silently poll production (which has no manifests yet).
LOOPY_UPDATE_CHANNEL ?= "production"

SRC_URI = "file://loopy.service \
           file://loopy-kiosk-launch \
           file://loopy-runtime.conf \
           file://loopy-rtirq.service \
           file://loopy-rtirq \
           file://loopy-data-grow.service \
           file://loopy-data-grow \
           file://data.mount \
           file://boot.mount \
           file://loopy-ota-check \
           file://loopy-ota-check.service \
           file://loopy-ota-check.timer \
           file://loopy-update-ctl \
           file://loopy-wifi-ctl \
           file://loopy-nm-persist \
           file://loopy-nm-persist.service \
           file://loopy-ssh-persist \
           file://loopy-ssh-persist.service \
           file://loopy-bt-persist \
           file://loopy-bt-persist.service \
           file://loopy-mark-good \
           file://loopy-mark-good.service \
           file://dropbear-loopy.conf \
           file://loopy-bt-ctl \
           file://loopy-brightness-ctl \
           file://99-loopy-wifi.conf \
           file://brcmfmac.conf \
           file://update-channel"

# No source tree (prebuilt install). walnascar bans S=${WORKDIR}; SRC_URI local
# files land in ${UNPACKDIR}, which do_install references directly.

# These are prebuilt aarch64 target binaries we install verbatim — do not let
# Yocto strip/relocate them or run host-oriented QA that assumes we compiled them.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
# Prebuilt binaries: skip already-stripped/arch/textrel QA, and file-rdeps too —
# the auto shlib scan can't map every SONAME for a binary we didn't compile. The
# actual libs still land in the image via the RDEPENDS below (the GTK stack).
INSANE_SKIP:${PN} += "already-stripped ldflags arch textrel file-rdeps"

# Contains target ELF/.so, so it is machine-specific, not allarch.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Runtime libs the GTK embedder + native engine link against, named explicitly so
# they're guaranteed in the image (hard `=`, so keep everything ON this line).
# curl/jq/ca-certificates: the OTA client (loopy-ota-check). rauc: the installer.
# parted + e2fsprogs-resize2fs: loopy-data-grow (expand /data to fill the SD card).
# avrdude + coreutils: loopy-update-ctl flash-pedal writes the published .hex to
# the Pro Micro (avrdude -c avr109) after stty does the Caterina 1200bps touch
# reset. avrdude comes from meta-loopy's own recipe (#430) — no layer we use
# ships one.
# networkmanager-nmcli: loopy-wifi-ctl (NM owns wpa_supplicant via -wifi plugin).
# bluez5: loopy-bt-ctl. ddcutil: loopy-brightness-ctl.
RDEPENDS:${PN} = "gtk+3 pango cairo gdk-pixbuf atk harfbuzz libepoxy \
                  fontconfig freetype glib-2.0 mesa alsa-lib libstdc++ \
                  curl jq ca-certificates rauc \
                  parted e2fsprogs-resize2fs \
                  networkmanager-nmcli networkmanager-wifi \
                  bluez5 ddcutil \
                  avrdude coreutils"

inherit systemd
# App + rtirq oneshot + data-grow oneshot + the /boot(tryboot selector) and
# /data mounts + the OTA update timer. Direct-ALSA appliance — no PipeWire/WirePlumber.
# The OTA check/install is OPT-IN: the app does the read-only manifest check on
# launch and the user triggers install/reboot from Settings (via loopy-update-ctl).
# So loopy-ota-check.timer is installed but NOT auto-enabled — no background
# auto-staging. (Re-enable the timer manually for a headless auto-update device.)
SYSTEMD_SERVICE:${PN} = "loopy.service loopy-rtirq.service loopy-data-grow.service loopy-nm-persist.service loopy-ssh-persist.service loopy-bt-persist.service loopy-mark-good.service boot.mount data.mount"

FILES:${PN} += "/opt/loopy ${bindir}/loopy-kiosk-launch ${bindir}/loopy-rtirq \
                ${bindir}/loopy-data-grow \
                ${bindir}/loopy-ota-check \
                ${bindir}/loopy-update-ctl \
                ${bindir}/loopy-wifi-ctl \
                ${bindir}/loopy-nm-persist \
                ${bindir}/loopy-ssh-persist \
                ${bindir}/loopy-bt-persist \
                ${bindir}/loopy-mark-good \
                ${bindir}/loopy-bt-ctl \
                ${bindir}/loopy-brightness-ctl \
                ${sysconfdir}/NetworkManager/conf.d/99-loopy-wifi.conf \
                ${sysconfdir}/systemd/system/dropbear@.service.d/loopy.conf \
                ${sysconfdir}/systemd/system/dropbearkey.service.d/loopy.conf \
                ${sysconfdir}/modprobe.d/brcmfmac.conf \
                ${sysconfdir}/loopy/update-channel ${sysconfdir}/loopy/build-version \
                ${systemd_system_unitdir}/loopy.service \
                ${systemd_system_unitdir}/loopy-rtirq.service \
                ${systemd_system_unitdir}/loopy-data-grow.service \
                ${systemd_system_unitdir}/loopy-nm-persist.service \
                ${systemd_system_unitdir}/loopy-ssh-persist.service \
                ${systemd_system_unitdir}/loopy-bt-persist.service \
                ${systemd_system_unitdir}/loopy-mark-good.service \
                ${systemd_system_unitdir}/boot.mount \
                ${systemd_system_unitdir}/data.mount \
                ${systemd_system_unitdir}/loopy-ota-check.service \
                ${systemd_system_unitdir}/loopy-ota-check.timer \
                ${sysconfdir}/tmpfiles.d/loopy-runtime.conf"

python do_fetch:prepend() {
    if not d.getVar('LOOPY_BUNDLE_DIR'):
        bb.fatal("LOOPY_BUNDLE_DIR is unset. Point it at the prebuilt bundle dir "
                 "(…/build/linux/arm64/release/bundle containing 'loopy').")
}

do_install() {
    bundle="${LOOPY_BUNDLE_DIR}"
    if [ ! -x "${bundle}/loopy" ]; then
        bbfatal "No 'loopy' binary under LOOPY_BUNDLE_DIR=${bundle}"
    fi

    install -d ${D}/opt/loopy
    # cp -R (not -a): preserve the executable bits but NOT the host uid/gid, then
    # force root ownership — staged files must not carry the build user's uid
    # (else do_package fails with "uid not found / host contamination").
    cp -R "${bundle}/." ${D}/opt/loopy/
    chown -R root:root ${D}/opt/loopy

    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/loopy-kiosk-launch ${D}${bindir}/loopy-kiosk-launch

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/loopy.service ${D}${systemd_system_unitdir}/loopy.service

    # rtirq: oneshot that raises the USB (xhci) sound-card IRQ thread to SCHED_FIFO
    # (above the app's audio thread) so the interrupt delivering a period preempts
    # the thread consuming it. Only meaningful with threaded IRQs (PREEMPT_RT
    # force-threads them; threadirqs on the cmdline otherwise).
    install -m 0755 ${UNPACKDIR}/loopy-rtirq ${D}${bindir}/loopy-rtirq
    install -m 0644 ${UNPACKDIR}/loopy-rtirq.service ${D}${systemd_system_unitdir}/loopy-rtirq.service

    # data-grow: oneshot that expands the seeded 2 GiB /data partition (and its
    # MBR extended container) to fill the SD card, then resize2fs. Idempotent;
    # runs before loopy.service. See loopy-data-grow + wic/loopy-tryboot.wks.
    install -m 0755 ${UNPACKDIR}/loopy-data-grow ${D}${bindir}/loopy-data-grow
    install -m 0644 ${UNPACKDIR}/loopy-data-grow.service ${D}${systemd_system_unitdir}/loopy-data-grow.service


    # Mount units: /boot = tryboot selector (autoboot.txt, for the RAUC backend),
    # /data = persistent app data (survives updates).
    install -m 0644 ${UNPACKDIR}/boot.mount ${D}${systemd_system_unitdir}/boot.mount
    install -m 0644 ${UNPACKDIR}/data.mount ${D}${systemd_system_unitdir}/data.mount

    # OTA update client: timer-driven check that polls the channel manifest on
    # segno.aquiles.dev and rauc-installs newer signed bundles (deferred activation).
    install -m 0755 ${UNPACKDIR}/loopy-ota-check ${D}${bindir}/loopy-ota-check
    install -m 0755 ${UNPACKDIR}/loopy-update-ctl ${D}${bindir}/loopy-update-ctl
    install -m 0644 ${UNPACKDIR}/loopy-ota-check.service ${D}${systemd_system_unitdir}/loopy-ota-check.service
    install -m 0644 ${UNPACKDIR}/loopy-ota-check.timer ${D}${systemd_system_unitdir}/loopy-ota-check.timer

    # Control Center host helpers (WiFi / Bluetooth / brightness) — Flutter
    # shells out to these the same way it drives loopy-update-ctl.
    install -m 0755 ${UNPACKDIR}/loopy-wifi-ctl ${D}${bindir}/loopy-wifi-ctl
    install -m 0755 ${UNPACKDIR}/loopy-bt-ctl ${D}${bindir}/loopy-bt-ctl
    install -m 0755 ${UNPACKDIR}/loopy-brightness-ctl ${D}${bindir}/loopy-brightness-ctl

    # NetworkManager appliance tweaks (WiFi join reliability on brcmfmac).
    # loopy-nm-persist: mkdir /data/NetworkManager/system-connections before NM
    # so keyfile.path (in 99-loopy-wifi.conf) survives A/B OTA.
    install -d ${D}${sysconfdir}/NetworkManager/conf.d
    install -m 0644 ${UNPACKDIR}/99-loopy-wifi.conf \
        ${D}${sysconfdir}/NetworkManager/conf.d/99-loopy-wifi.conf
    install -m 0755 ${UNPACKDIR}/loopy-nm-persist ${D}${bindir}/loopy-nm-persist
    install -m 0644 ${UNPACKDIR}/loopy-nm-persist.service \
        ${D}${systemd_system_unitdir}/loopy-nm-persist.service

    # BlueZ has no keyfile.path equivalent, so loopy-bt-persist bind-mounts
    # /data/bluetooth over /var/lib/bluetooth before bluetoothd starts (#451).
    install -m 0755 ${UNPACKDIR}/loopy-bt-persist ${D}${bindir}/loopy-bt-persist
    install -m 0644 ${UNPACKDIR}/loopy-bt-persist.service \
        ${D}${systemd_system_unitdir}/loopy-bt-persist.service

    # meta-rauc's own rauc-mark-good.service is condition-gated on a rauc.slot
    # kernel argument the Pi tryboot backend never sets, so it is skipped every
    # boot and every update silently rolls back. This replaces it, behind a
    # health gate (#307).
    install -m 0755 ${UNPACKDIR}/loopy-mark-good ${D}${bindir}/loopy-mark-good
    install -m 0644 ${UNPACKDIR}/loopy-mark-good.service \
        ${D}${systemd_system_unitdir}/loopy-mark-good.service

    # Dropbear host keys on /data so A/B OTA does not rotate SSH identity (#309).
    install -m 0755 ${UNPACKDIR}/loopy-ssh-persist ${D}${bindir}/loopy-ssh-persist
    install -m 0644 ${UNPACKDIR}/loopy-ssh-persist.service \
        ${D}${systemd_system_unitdir}/loopy-ssh-persist.service
    install -d ${D}${sysconfdir}/systemd/system/dropbear@.service.d
    install -d ${D}${sysconfdir}/systemd/system/dropbearkey.service.d
    install -m 0644 ${UNPACKDIR}/dropbear-loopy.conf \
        ${D}${sysconfdir}/systemd/system/dropbear@.service.d/loopy.conf
    install -m 0644 ${UNPACKDIR}/dropbear-loopy.conf \
        ${D}${sysconfdir}/systemd/system/dropbearkey.service.d/loopy.conf

    # brcmfmac: roamoff=1 — without this, WPA2 associates then never completes
    # the 4-way handshake on many APs (no EAPOL M1).
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${UNPACKDIR}/brcmfmac.conf \
        ${D}${sysconfdir}/modprobe.d/brcmfmac.conf

    # /etc/loopy: update channel + this build's version number.
    # Prefer LOOPY_UPDATE_CHANNEL (set by CI) over the static file default.
    # vardeps below force a rebuild when CI changes either stamp.
    install -d ${D}${sysconfdir}/loopy
    printf '%s\n' "${LOOPY_UPDATE_CHANNEL}" > ${D}${sysconfdir}/loopy/update-channel
    echo "${LOOPY_BUILD_VERSION}" > ${D}${sysconfdir}/loopy/build-version

    # tmpfiles.d rule that creates /run/user/1000 for the weston user at boot
    # (no logind session makes it otherwise; weston crash-loops without it).
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/loopy-runtime.conf ${D}${sysconfdir}/tmpfiles.d/loopy-runtime.conf
}

# Rebuild when CI stamps a new version/channel (otherwise sstate can leave a
# stale /etc/loopy/* from a prior package).
do_install[vardeps] += "LOOPY_BUILD_VERSION LOOPY_UPDATE_CHANNEL"
