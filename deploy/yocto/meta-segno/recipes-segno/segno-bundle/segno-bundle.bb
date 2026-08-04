SUMMARY = "Prebuilt Segno Flutter GTK bundle (installed as-is; NOT built from source)"
DESCRIPTION = "Installs the exact aarch64 Flutter GTK bundle produced by \
deploy/rpi/build/build-arm64-bundle.sh into /opt/segno, plus a Wayland launcher \
and a systemd unit that runs it under weston. See docs/plan Tier 3a §Phase 2."
# CLOSED: a prebuilt binary we install verbatim — no in-tree license file to
# checksum here (the app's licensing lives in the main repo, not this recipe).
LICENSE = "CLOSED"

# Path to the prebuilt bundle dir (contains 'segno', libflutter_linux_gtk.so,
# libsegno_engine.so, data/). Defaults to deploy/yocto/prebuilt/bundle relative to
# this recipe (resolves inside the build container regardless of mount point);
# override via SEGNO_BUNDLE_DIR in kas/local.conf to point elsewhere.
SEGNO_BUNDLE_DIR ?= "${THISDIR}/../../../prebuilt/bundle"

# Semver (e.g. "0.2.0" or "0.2.0-experimental.42") stamped into
# /etc/segno/build-version; the OTA client compares the channel manifest's
# version against it. CI sets SEGNO_BUILD_VERSION per release.
SEGNO_BUILD_VERSION ?= "0.0.0"

# Channel stamped into /etc/segno/update-channel (`experimental` / `production`).
# CI sets this to match the release channel so experimental images don't
# silently poll production (which has no manifests yet).
SEGNO_UPDATE_CHANNEL ?= "production"

SRC_URI = "file://segno.service \
           file://segno-kiosk-launch \
           file://segno-runtime.conf \
           file://segno-rtirq.service \
           file://segno-rtirq \
           file://segno-data-grow.service \
           file://segno-data-grow \
           file://data.mount \
           file://boot.mount \
           file://segno-ota-check \
           file://segno-ota-check.service \
           file://segno-ota-check.timer \
           file://segno-update-ctl \
           file://segno-wifi-ctl \
           file://segno-nm-persist \
           file://segno-nm-persist.service \
           file://segno-ssh-persist \
           file://segno-ssh-persist.service \
           file://segno-bt-persist \
           file://segno-bt-persist.service \
           file://segno-mark-good \
           file://segno-mark-good.service \
           file://dropbear-segno.conf \
           file://segno-bt-ctl \
           file://segno-brightness-ctl \
           file://99-segno-wifi.conf \
           file://segno-wifi-regdom \
           file://segno-wifi-regdom.service \
           file://wifi-country-default \
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
# curl/jq/ca-certificates: the OTA client (segno-ota-check). rauc: the installer.
# parted + e2fsprogs-resize2fs: segno-data-grow (expand /data to fill the SD card).
# avrdude + coreutils: segno-update-ctl flash-pedal writes the published .hex to
# the Pro Micro (avrdude -c avr109) after stty does the Caterina 1200bps touch
# reset. avrdude comes from meta-segno's own recipe (#430) — no layer we use
# ships one.
# iw: segno-wifi-regdom. NOT wireless-regdb — packagegroup-base-wifi already
# pulls wireless-regdb-static and the two RCONFLICT, so requesting the modern
# db here fails the rootfs outright. Whether this kernel reads the CRDA
# regulatory.bin the image has, or the /lib/firmware/regulatory.db it does not,
# is answered on device: segno-wifi-regdom warns when the latter is missing.
# networkmanager-nmcli: segno-wifi-ctl (NM owns wpa_supplicant via -wifi plugin).
# bluez5: segno-bt-ctl. ddcutil: segno-brightness-ctl.
RDEPENDS:${PN} = "gtk+3 pango cairo gdk-pixbuf atk harfbuzz libepoxy \
                  fontconfig freetype glib-2.0 mesa alsa-lib libstdc++ \
                  curl jq ca-certificates rauc \
                  parted e2fsprogs-resize2fs \
                  networkmanager-nmcli networkmanager-wifi \
                  bluez5 ddcutil \
                  iw \
                  avrdude coreutils"

inherit systemd
# App + rtirq oneshot + data-grow oneshot + the /boot(tryboot selector) and
# /data mounts + the OTA update timer. Direct-ALSA appliance — no PipeWire/WirePlumber.
# The OTA check/install is OPT-IN: the app does the read-only manifest check on
# launch and the user triggers install/reboot from Settings (via segno-update-ctl).
# So segno-ota-check.timer is installed but NOT auto-enabled — no background
# auto-staging. (Re-enable the timer manually for a headless auto-update device.)
SYSTEMD_SERVICE:${PN} = "segno.service segno-rtirq.service segno-data-grow.service segno-nm-persist.service segno-wifi-regdom.service segno-ssh-persist.service segno-bt-persist.service segno-mark-good.service boot.mount data.mount"

FILES:${PN} += "/opt/segno ${bindir}/segno-kiosk-launch ${bindir}/segno-rtirq \
                ${bindir}/segno-data-grow \
                ${bindir}/segno-ota-check \
                ${bindir}/segno-update-ctl \
                ${bindir}/segno-wifi-ctl \
                ${bindir}/segno-nm-persist \
                ${bindir}/segno-wifi-regdom \
                ${bindir}/segno-ssh-persist \
                ${bindir}/segno-bt-persist \
                ${bindir}/segno-mark-good \
                ${bindir}/segno-bt-ctl \
                ${bindir}/segno-brightness-ctl \
                ${sysconfdir}/NetworkManager/conf.d/99-segno-wifi.conf \
                ${sysconfdir}/systemd/system/dropbear@.service.d/segno.conf \
                ${sysconfdir}/systemd/system/dropbearkey.service.d/segno.conf \
                ${sysconfdir}/modprobe.d/brcmfmac.conf \
                ${sysconfdir}/segno/update-channel ${sysconfdir}/segno/build-version \
                ${sysconfdir}/segno/wifi-country \
                ${systemd_system_unitdir}/segno.service \
                ${systemd_system_unitdir}/segno-rtirq.service \
                ${systemd_system_unitdir}/segno-data-grow.service \
                ${systemd_system_unitdir}/segno-nm-persist.service \
                ${systemd_system_unitdir}/segno-wifi-regdom.service \
                ${systemd_system_unitdir}/segno-ssh-persist.service \
                ${systemd_system_unitdir}/segno-bt-persist.service \
                ${systemd_system_unitdir}/segno-mark-good.service \
                ${systemd_system_unitdir}/boot.mount \
                ${systemd_system_unitdir}/data.mount \
                ${systemd_system_unitdir}/segno-ota-check.service \
                ${systemd_system_unitdir}/segno-ota-check.timer \
                ${sysconfdir}/systemd/system/wpa_supplicant.service \
                ${sysconfdir}/systemd/system/serial-getty@ttyS0.service \
                ${sysconfdir}/tmpfiles.d/segno-runtime.conf"

python do_fetch:prepend() {
    if not d.getVar('SEGNO_BUNDLE_DIR'):
        bb.fatal("SEGNO_BUNDLE_DIR is unset. Point it at the prebuilt bundle dir "
                 "(…/build/linux/arm64/release/bundle containing 'segno').")
}

do_install() {
    bundle="${SEGNO_BUNDLE_DIR}"
    if [ ! -x "${bundle}/segno" ]; then
        bbfatal "No 'segno' binary under SEGNO_BUNDLE_DIR=${bundle}"
    fi

    install -d ${D}/opt/segno
    # cp -R (not -a): preserve the executable bits but NOT the host uid/gid, then
    # force root ownership — staged files must not carry the build user's uid
    # (else do_package fails with "uid not found / host contamination").
    cp -R "${bundle}/." ${D}/opt/segno/
    chown -R root:root ${D}/opt/segno

    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/segno-kiosk-launch ${D}${bindir}/segno-kiosk-launch

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/segno.service ${D}${systemd_system_unitdir}/segno.service

    # rtirq: oneshot that raises the USB (xhci) sound-card IRQ thread to SCHED_FIFO
    # (above the app's audio thread) so the interrupt delivering a period preempts
    # the thread consuming it. Only meaningful with threaded IRQs (PREEMPT_RT
    # force-threads them; threadirqs on the cmdline otherwise).
    install -m 0755 ${UNPACKDIR}/segno-rtirq ${D}${bindir}/segno-rtirq
    install -m 0644 ${UNPACKDIR}/segno-rtirq.service ${D}${systemd_system_unitdir}/segno-rtirq.service

    # data-grow: oneshot that expands the seeded 2 GiB /data partition (and its
    # MBR extended container) to fill the SD card, then resize2fs. Idempotent;
    # runs before segno.service. See segno-data-grow + wic/segno-tryboot.wks.
    install -m 0755 ${UNPACKDIR}/segno-data-grow ${D}${bindir}/segno-data-grow
    install -m 0644 ${UNPACKDIR}/segno-data-grow.service ${D}${systemd_system_unitdir}/segno-data-grow.service


    # Mount units: /boot = tryboot selector (autoboot.txt, for the RAUC backend),
    # /data = persistent app data (survives updates).
    install -m 0644 ${UNPACKDIR}/boot.mount ${D}${systemd_system_unitdir}/boot.mount
    install -m 0644 ${UNPACKDIR}/data.mount ${D}${systemd_system_unitdir}/data.mount

    # OTA update client: timer-driven check that polls the channel manifest on
    # segno.aquiles.dev and rauc-installs newer signed bundles (deferred activation).
    install -m 0755 ${UNPACKDIR}/segno-ota-check ${D}${bindir}/segno-ota-check
    install -m 0755 ${UNPACKDIR}/segno-update-ctl ${D}${bindir}/segno-update-ctl
    install -m 0644 ${UNPACKDIR}/segno-ota-check.service ${D}${systemd_system_unitdir}/segno-ota-check.service
    install -m 0644 ${UNPACKDIR}/segno-ota-check.timer ${D}${systemd_system_unitdir}/segno-ota-check.timer

    # Control Center host helpers (WiFi / Bluetooth / brightness) — Flutter
    # shells out to these the same way it drives segno-update-ctl.
    install -m 0755 ${UNPACKDIR}/segno-wifi-ctl ${D}${bindir}/segno-wifi-ctl
    install -m 0755 ${UNPACKDIR}/segno-bt-ctl ${D}${bindir}/segno-bt-ctl
    install -m 0755 ${UNPACKDIR}/segno-brightness-ctl ${D}${bindir}/segno-brightness-ctl

    # NetworkManager appliance tweaks (WiFi join reliability on brcmfmac).
    # segno-nm-persist: mkdir /data/NetworkManager/system-connections before NM
    # so keyfile.path (in 99-segno-wifi.conf) survives A/B OTA.
    install -d ${D}${sysconfdir}/NetworkManager/conf.d
    install -m 0644 ${UNPACKDIR}/99-segno-wifi.conf \
        ${D}${sysconfdir}/NetworkManager/conf.d/99-segno-wifi.conf
    # The world regdom leaves 5 GHz ch 36-48 passive-scan, which lets a 5 GHz
    # AP associate and then silently fail EAPOL (#459). iw + a signed
    # regulatory.db are what make `iw reg set` actually take.
    install -m 0755 ${UNPACKDIR}/segno-wifi-regdom ${D}${bindir}/segno-wifi-regdom
    install -m 0644 ${UNPACKDIR}/segno-wifi-regdom.service \
        ${D}${systemd_system_unitdir}/segno-wifi-regdom.service
    install -d ${D}${sysconfdir}/segno
    install -m 0644 ${UNPACKDIR}/wifi-country-default \
        ${D}${sysconfdir}/segno/wifi-country

    install -m 0755 ${UNPACKDIR}/segno-nm-persist ${D}${bindir}/segno-nm-persist
    install -m 0644 ${UNPACKDIR}/segno-nm-persist.service \
        ${D}${systemd_system_unitdir}/segno-nm-persist.service

    # Units masked by symlinking to /dev/null. The directory has to exist
    # before anything links into it — putting a mask above this line is what
    # broke the first build after #464.
    install -d ${D}${sysconfdir}/systemd/system

    # Nothing on this board exposes /dev/ttyS0, so serial-getty@ttyS0 waits out
    # systemd's 90s device timeout on every boot — 90 seconds of a dark screen
    # on an appliance, for a console nobody uses (#464).
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/serial-getty@ttyS0.service

    # iwd owns the radio now (#468 step 2). wpa_supplicant is still pulled into
    # the image by packagegroup-base-wifi, and letting it get dbus-activated
    # alongside iwd would recreate the two-supplicants bug this release exists
    # to remove — so mask it rather than trust that nothing activates it.
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/wpa_supplicant.service

    # BlueZ has no keyfile.path equivalent, so segno-bt-persist bind-mounts
    # /data/bluetooth over /var/lib/bluetooth before bluetoothd starts (#451).
    install -m 0755 ${UNPACKDIR}/segno-bt-persist ${D}${bindir}/segno-bt-persist
    install -m 0644 ${UNPACKDIR}/segno-bt-persist.service \
        ${D}${systemd_system_unitdir}/segno-bt-persist.service

    # meta-rauc's own rauc-mark-good.service is condition-gated on a rauc.slot
    # kernel argument the Pi tryboot backend never sets, so it is skipped every
    # boot and every update silently rolls back. This replaces it, behind a
    # health gate (#307).
    install -m 0755 ${UNPACKDIR}/segno-mark-good ${D}${bindir}/segno-mark-good
    install -m 0644 ${UNPACKDIR}/segno-mark-good.service \
        ${D}${systemd_system_unitdir}/segno-mark-good.service

    # Dropbear host keys on /data so A/B OTA does not rotate SSH identity (#309).
    install -m 0755 ${UNPACKDIR}/segno-ssh-persist ${D}${bindir}/segno-ssh-persist
    install -m 0644 ${UNPACKDIR}/segno-ssh-persist.service \
        ${D}${systemd_system_unitdir}/segno-ssh-persist.service
    install -d ${D}${sysconfdir}/systemd/system/dropbear@.service.d
    install -d ${D}${sysconfdir}/systemd/system/dropbearkey.service.d
    install -m 0644 ${UNPACKDIR}/dropbear-segno.conf \
        ${D}${sysconfdir}/systemd/system/dropbear@.service.d/segno.conf
    install -m 0644 ${UNPACKDIR}/dropbear-segno.conf \
        ${D}${sysconfdir}/systemd/system/dropbearkey.service.d/segno.conf

    # brcmfmac: roamoff=1 — without this, WPA2 associates then never completes
    # the 4-way handshake on many APs (no EAPOL M1).
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${UNPACKDIR}/brcmfmac.conf \
        ${D}${sysconfdir}/modprobe.d/brcmfmac.conf

    # /etc/segno: update channel + this build's version number.
    # Prefer SEGNO_UPDATE_CHANNEL (set by CI) over the static file default.
    # vardeps below force a rebuild when CI changes either stamp.
    install -d ${D}${sysconfdir}/segno
    printf '%s\n' "${SEGNO_UPDATE_CHANNEL}" > ${D}${sysconfdir}/segno/update-channel
    echo "${SEGNO_BUILD_VERSION}" > ${D}${sysconfdir}/segno/build-version

    # tmpfiles.d rule that creates /run/user/1000 for the weston user at boot
    # (no logind session makes it otherwise; weston crash-loops without it).
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/segno-runtime.conf ${D}${sysconfdir}/tmpfiles.d/segno-runtime.conf
}

# Rebuild when CI stamps a new version/channel (otherwise sstate can leave a
# stale /etc/segno/* from a prior package).
do_install[vardeps] += "SEGNO_BUILD_VERSION SEGNO_UPDATE_CHANNEL"
