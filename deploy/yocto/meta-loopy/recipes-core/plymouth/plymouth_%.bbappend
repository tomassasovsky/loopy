# We boot straight from the rootfs (no initramfs), so plymouth's runtime dracut
# dependency (for regenerating an initramfs with the plymouth module) is dead
# weight and isn't provided by our layers. Drop it.
RDEPENDS:${PN}:remove = "dracut"
