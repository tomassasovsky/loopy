# Boot is straight from the rootfs (no initramfs): drop the 'initrd' PACKAGECONFIG
# so the plymouth-initrd package (which RDEPENDS dracut, unprovided here) isn't built.
PACKAGECONFIG:remove = "initrd"

# The 'drm' renderer is only auto-enabled for x86 in the base recipe, but the Pi 4
# needs it to draw the splash on the vc4 framebuffer. 'script' is our theme's engine.
PACKAGECONFIG:append = " drm script"

# Select the loopy theme as the boot default.
#
# Plymouth resolves its theme from the 'Theme=' key in /etc/plymouth/plymouthd.conf
# (admin, commented out by default), falling back to /usr/share/plymouth/plymouthd.defaults.
# The stock defaults ship 'Theme=spinner' (the generic two-step circular spinner), and
# that key takes precedence over the themes/default.plymouth symlink — so despite the
# plymouth-loopy-theme recipe pointing default.plymouth at loopy, boot loaded two-step.so
# and showed the circular spinner. Repoint the distro default at loopy so script.so (our
# theme engine) is loaded instead. The default.plymouth symlink remains as a fallback.
do_install:append() {
    if [ -f ${D}${datadir}/plymouth/plymouthd.defaults ]; then
        sed -i 's/^Theme=.*/Theme=loopy/' ${D}${datadir}/plymouth/plymouthd.defaults
    fi
}
