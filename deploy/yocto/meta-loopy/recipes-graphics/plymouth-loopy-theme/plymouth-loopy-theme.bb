SUMMARY = "Loopy floor-console Plymouth boot splash (segno lockup, shimmer + progress)"
DESCRIPTION = "A script-based Plymouth theme: the segno lockup — the Bravura mark \
(SMuFL glyph U+E047) over the Apple Chancery 'segno' wordmark, both pre-rendered \
from smooth glyph vectors — centred on the console's near-black (#08080A) with a \
gentle luminance shimmer and a determinate progress bar driven by the real boot \
progress. No text banners, no Raspberry Pi rainbow. Shown from early boot until \
weston/loopy takes the display."
LICENSE = "CLOSED"

SRC_URI = "file://loopy.plymouth \
           file://loopy.script \
           file://loopy-lockup.png \
           file://loopy-bar-pixel.png \
           file://weston-after-plymouth.conf"

RDEPENDS:${PN} = "plymouth"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${datadir}/plymouth/themes/loopy
    install -m 0644 ${UNPACKDIR}/loopy.plymouth ${D}${datadir}/plymouth/themes/loopy/loopy.plymouth
    install -m 0644 ${UNPACKDIR}/loopy.script   ${D}${datadir}/plymouth/themes/loopy/loopy.script
    install -m 0644 ${UNPACKDIR}/loopy-lockup.png    ${D}${datadir}/plymouth/themes/loopy/loopy-lockup.png
    install -m 0644 ${UNPACKDIR}/loopy-bar-pixel.png ${D}${datadir}/plymouth/themes/loopy/loopy-bar-pixel.png

    # Select loopy as the active theme via the default.plymouth symlink (plymouth's
    # own plymouthd.conf leaves Theme= commented, so the symlink wins). Relative so
    # it resolves on-target.
    ln -sf loopy/loopy.plymouth ${D}${datadir}/plymouth/themes/default.plymouth

    # weston waits for plymouth to release the DRM master before grabbing it.
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/weston-after-plymouth.conf ${D}${systemd_system_unitdir}/weston.service.d/10-after-plymouth.conf
}

FILES:${PN} = "${datadir}/plymouth/themes/loopy \
               ${datadir}/plymouth/themes/default.plymouth \
               ${systemd_system_unitdir}/weston.service.d/10-after-plymouth.conf"
