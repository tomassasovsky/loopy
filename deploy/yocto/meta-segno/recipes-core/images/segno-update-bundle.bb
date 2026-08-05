SUMMARY = "RAUC update bundle (.raucb) for the Segno appliance — the rootfs slot"
# Builds a signed, verity-format RAUC bundle carrying segno-kiosk-image's rootfs.
# `rauc install` writes it to the inactive A/B slot. CI publishes it per channel.
inherit bundle

RAUC_BUNDLE_FORMAT     = "verity"
# MUST byte-match [system] compatible in recipes-core/rauc/files/system.conf.
RAUC_BUNDLE_COMPATIBLE = "segno-raspberrypi4"
# The build number (CI sets it), same value stamped into /etc/segno/build-version.
# Deterministic — using ${DATETIME} makes the task basehash non-reproducible.
SEGNO_BUILD_VERSION   ?= "0"
RAUC_BUNDLE_VERSION    = "${SEGNO_BUILD_VERSION}"

# Signing material. RAUC_KEYDIR holds development-1.{key,cert}.pem. Default is a
# gitignored dir INSIDE meta-segno so it's visible inside the kas container (which
# only mounts the repo). The PRIVATE key is never committed — populate this dir on
# the build host (and from a secret in CI). Layer-relative so it works under any mount.
RAUC_KEYDIR   ?= "${THISDIR}/../../.rauc-keys"
RAUC_KEY_FILE  = "${RAUC_KEYDIR}/development-1.key.pem"
RAUC_CERT_FILE = "${RAUC_KEYDIR}/development-1.cert.pem"

python __anonymous() {
    import os
    keyfile = d.getVar("RAUC_KEY_FILE")
    if not keyfile or not os.path.exists(keyfile):
        raise bb.parse.SkipRecipe(
            "RAUC signing key not found at %s. Put development-1.{key,cert}.pem in "
            "RAUC_KEYDIR (default meta-segno/.rauc-keys, gitignored) to build the "
            "update bundle." % keyfile)
}

# One slot: the whole rootfs. (Kernel lives in the boot slot; grouping the boot
# slot into the bundle is a follow-up once single-rootfs updates are proven.)
RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs  = "segno-kiosk-image"
RAUC_SLOT_rootfs[fstype] = "ext4"
