SUMMARY = "RAUC custom bootloader backend for the Raspberry Pi firmware (tryboot A/B)"
DESCRIPTION = "Vendored from Rtone/raspberrypi-firmware-rauc-bootloader-backend: the \
custom-bootloader-backend script RAUC calls (get/set-primary/state, get-current) which \
drives the RPi one-shot tryboot flag (vcmailbox) + autoboot.txt swap, plus the \
system-info handler. The rauc-mark-good.service comes from meta-rauc's own \
rauc-mark-good package (added to the image), not here."
LICENSE = "LGPL-2.1-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/LGPL-2.1-only;md5=1a6d268fd218675ffea8be556788b780"

SRC_URI = "file://bootloader-custom-backend \
           file://system-info"

# bash: the backend + system-info are bash. raspi-utils: vcmailbox (the tryboot
# one-shot flag). dtc: fdtget (reads /chosen/bootloader from the fdt).
RDEPENDS:${PN} = "bash raspi-utils dtc"

do_install() {
    install -d ${D}${nonarch_libdir}/rauc/rpi-firmware
    install -m 0755 ${UNPACKDIR}/bootloader-custom-backend ${D}${nonarch_libdir}/rauc/rpi-firmware/bootloader-custom-backend
    install -m 0755 ${UNPACKDIR}/system-info ${D}${nonarch_libdir}/rauc/rpi-firmware/system-info
}

FILES:${PN} = "${nonarch_libdir}/rauc/rpi-firmware"
