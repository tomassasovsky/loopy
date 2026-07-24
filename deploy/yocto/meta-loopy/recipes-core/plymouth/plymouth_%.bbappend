# Boot is straight from the rootfs (no initramfs): drop the 'initrd' PACKAGECONFIG
# so the plymouth-initrd package (which RDEPENDS dracut, unprovided here) isn't built.
PACKAGECONFIG:remove = "initrd"

# The 'drm' renderer is only auto-enabled for x86 in the base recipe, but the Pi 4
# needs it to draw the splash on the vc4 framebuffer. 'script' is our theme's engine.
PACKAGECONFIG:append = " drm script"
