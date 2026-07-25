# Override meta-rauc's example rauc-conf (the virtual-rauc-conf provider that owns
# /etc/rauc/system.conf) with the appliance's tryboot A/B config, and add the
# keyring (public CA cert). FILESEXTRAPATHS:prepend makes our files/system.conf win
# over meta-rauc's when the rauc-conf recipe fetches file://system.conf.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://ca.cert.pem"

do_install:append() {
    install -d ${D}${sysconfdir}/rauc
    install -m 0644 ${UNPACKDIR}/ca.cert.pem ${D}${sysconfdir}/rauc/keyring.pem
}

FILES:${PN} += "${sysconfdir}/rauc/keyring.pem"
