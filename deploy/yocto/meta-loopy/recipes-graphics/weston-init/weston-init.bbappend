# Override the stock weston.ini with a kiosk-shell + dual-HDMI config for the
# floor console (Tier 3a spike). Our layer's higher BBFILE_PRIORITY makes this
# weston.ini win over the default.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://weston.ini"

do_install:append() {
    install -Dm 0644 ${WORKDIR}/weston.ini ${D}${sysconfdir}/xdg/weston/weston.ini
}
