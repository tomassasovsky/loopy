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

SRC_URI = "file://loopy.service \
           file://loopy-kiosk-launch"

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
# they're guaranteed in the image. Verify the full set on device with
# `ldd /opt/loopy/loopy` — this is the ABI-matching risk (plan §Risks).
RDEPENDS:${PN} = "gtk+3 pango cairo gdk-pixbuf atk harfbuzz libepoxy \
                  fontconfig freetype glib-2.0 mesa alsa-lib libstdc++"

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
    # cp -R (not -a): preserve the executable bits but NOT the host uid/gid, then
    # force root ownership — staged files must not carry the build user's uid
    # (else do_package fails with "uid not found / host contamination").
    cp -R "${bundle}/." ${D}/opt/loopy/
    chown -R root:root ${D}/opt/loopy

    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/loopy-kiosk-launch ${D}${bindir}/loopy-kiosk-launch

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/loopy.service ${D}${systemd_system_unitdir}/loopy.service
}
