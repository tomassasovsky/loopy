SUMMARY = "Loopy floor-console Plymouth boot splash (Bravura segno, breathe + shimmer)"
DESCRIPTION = "A script-based Plymouth theme: the segno mark (rendered to a PNG from \
the OFL-licensed Bravura music font, SMuFL glyph U+E047) centred on the console's \
near-black (#08080A) with a slow breathe (scale) + shimmer (luminance) animation. \
No progress bar, no text, no Raspberry Pi rainbow. Shown from early boot until \
weston/loopy takes the display."
LICENSE = "CLOSED"

SRC_URI = "file://loopy.plymouth \
           file://loopy.script \
           file://loopy-segno.png \
           file://plymouthd.conf \
           file://weston-after-plymouth.conf"

RDEPENDS:${PN} = "plymouth"
# PNG is theme data but this pins it to the machine image alongside plymouth.
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${datadir}/plymouth/themes/loopy
    install -m 0644 ${UNPACKDIR}/loopy.plymouth ${D}${datadir}/plymouth/themes/loopy/loopy.plymouth
    install -m 0644 ${UNPACKDIR}/loopy.script   ${D}${datadir}/plymouth/themes/loopy/loopy.script
    install -m 0644 ${UNPACKDIR}/loopy-segno.png ${D}${datadir}/plymouth/themes/loopy/loopy-segno.png

    # Select this theme (Theme= wins over the default.plymouth symlink).
    install -d ${D}${sysconfdir}/plymouth
    install -m 0644 ${UNPACKDIR}/plymouthd.conf ${D}${sysconfdir}/plymouth/plymouthd.conf

    # weston waits for plymouth to release the DRM master (drop-in).
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/weston-after-plymouth.conf ${D}${systemd_system_unitdir}/weston.service.d/10-after-plymouth.conf
}

FILES:${PN} = "${datadir}/plymouth/themes/loopy ${sysconfdir}/plymouth/plymouthd.conf ${systemd_system_unitdir}/weston.service.d/10-after-plymouth.conf"
