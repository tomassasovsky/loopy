# Vendored from meta-wayland (walnascar) — we don't pull that whole layer in
# just for brightness. Powers loopy-brightness-ctl (DDC/CI VCP 0x10).
SUMMARY = "Query and change monitor settings (brightness, etc.) via DDC/CI"
HOMEPAGE = "https://github.com/rockowitz/ddcutil"
SECTION = "utils"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=b234ee4d69f5fce4486a80fdaf4a4263"

SRC_URI = "git://github.com/rockowitz/ddcutil.git;protocol=https;branch=master"

DEPENDS = "i2c-tools glib-2.0 kmod jansson"

S = "${WORKDIR}/git"
PV = "2.1.4"
SRCREV = "ca610f91d5483e19bfdae88bb0094973cc81fc95"

inherit autotools pkgconfig

# Headless appliance: DRM + udev + USB; skip X11 (we have Wayland/weston).
PACKAGECONFIG ??= "drm systemd usb"
PACKAGECONFIG[drm] = "--enable-drm=yes,--enable-drm=no,libdrm"
PACKAGECONFIG[systemd] = "--enable-udev=yes,--enable-udev=no,udev"
PACKAGECONFIG[usb] = "--enable-usb=yes,--enable-usb=no,libusb1"
PACKAGECONFIG[x11] = "--enable-x11=yes,--enable-x11=no,libx11 xrandr"

CFLAGS += "-Wno-unused-but-set-variable"

do_install:append() {
    if [ -d "${D}${datadir}/ddcutil/data" ]; then
        install -d ${D}${sysconfdir}/udev/rules.d
        cp -rf ${D}${datadir}/ddcutil/data/* ${D}${sysconfdir}/udev/rules.d
    fi
}

FILES:${PN} += "${sysconfdir} ${libdir}/modules-load.d/ddcutil.conf"
