SUMMARY = "Prebuilt Loopy Flutter GTK bundle (installed as-is; NOT built from source)"
DESCRIPTION = "Installs the exact aarch64 Flutter GTK bundle produced by \
deploy/rpi/build/build-arm64-bundle.sh into /opt/loopy, plus a Wayland launcher \
and a systemd unit that runs it under weston. See docs/plan Tier 3a §Phase 2."
LICENSE = "MIT"

# Path to the prebuilt bundle dir (contains 'loopy', libflutter_linux_gtk.so,
# libloopy_engine.so, data/). Set via LOOPY_BUNDLE_DIR in kas/local.conf.
LOOPY_BUNDLE_DIR ?= ""

SRC_URI = "file://loopy.service \
           file://loopy-kiosk-launch"

S = "${WORKDIR}"

# These are prebuilt aarch64 target binaries we install verbatim — do not let
# Yocto strip/relocate them or run host-oriented QA that assumes we compiled them.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags arch textrel"

# Contains target ELF/.so, so it is machine-specific, not allarch.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Runtime libs the GTK embedder + native engine link against. Verify on device
# with `ldd /opt/loopy/loopy` — this is the ABI-matching risk (plan §Risks).
RDEPENDS:${PN} = "gtk+3 mesa alsa-lib libstdc++ glib-2.0"

inherit systemd
SYSTEMD_SERVICE:${PN} = "loopy.service"

FILES:${PN} += "/opt/loopy ${bindir}/loopy-kiosk-launch ${systemd_system_unitdir}/loopy.service"

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
    cp -a "${bundle}/." ${D}/opt/loopy/

    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/loopy-kiosk-launch ${D}${bindir}/loopy-kiosk-launch

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/loopy.service ${D}${systemd_system_unitdir}/loopy.service
}
