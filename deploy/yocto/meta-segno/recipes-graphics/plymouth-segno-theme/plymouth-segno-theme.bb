SUMMARY = "Segno floor-console Plymouth boot splash (segno lockup, shimmer + progress)"
DESCRIPTION = "A script-based Plymouth theme: the segno lockup — the Bravura mark \
(SMuFL glyph U+E047) over the Apple Chancery 'segno' wordmark, both pre-rendered \
from smooth glyph vectors — centred on the console's near-black (#08080A) with a \
gentle luminance shimmer and a determinate progress bar driven by the real boot \
progress. No text banners, no Raspberry Pi rainbow. Shown from early boot until \
weston/segno takes the display."
LICENSE = "CLOSED"

SRC_URI = "file://segno.plymouth \
           file://segno.script \
           file://segno-lockup.png \
           file://segno-bar-pixel.png \
           file://weston-after-plymouth.conf"

RDEPENDS:${PN} = "plymouth"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${datadir}/plymouth/themes/segno
    install -m 0644 ${UNPACKDIR}/segno.plymouth ${D}${datadir}/plymouth/themes/segno/segno.plymouth
    install -m 0644 ${UNPACKDIR}/segno.script   ${D}${datadir}/plymouth/themes/segno/segno.script
    install -m 0644 ${UNPACKDIR}/segno-lockup.png    ${D}${datadir}/plymouth/themes/segno/segno-lockup.png
    install -m 0644 ${UNPACKDIR}/segno-bar-pixel.png ${D}${datadir}/plymouth/themes/segno/segno-bar-pixel.png

    # Select segno as the active theme via the default.plymouth symlink (plymouth's
    # own plymouthd.conf leaves Theme= commented, so the symlink wins). Relative so
    # it resolves on-target.
    ln -sf segno/segno.plymouth ${D}${datadir}/plymouth/themes/default.plymouth

    # weston waits for plymouth to release the DRM master before grabbing it.
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/weston-after-plymouth.conf ${D}${systemd_system_unitdir}/weston.service.d/10-after-plymouth.conf
}

FILES:${PN} = "${datadir}/plymouth/themes/segno \
               ${datadir}/plymouth/themes/default.plymouth \
               ${systemd_system_unitdir}/weston.service.d/10-after-plymouth.conf"
