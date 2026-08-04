SUMMARY = "AVR microcontroller programmer"
DESCRIPTION = "avrdude programs Atmel AVR microcontrollers. On the segno \
appliance it is used by `segno-update-ctl flash-pedal` to write the published \
pedal firmware to the Pro Micro's Caterina bootloader over its CDC serial \
port (-c avr109), so the pedal updates with the app instead of by hand."
HOMEPAGE = "https://github.com/avrdudes/avrdude"
SECTION = "devel"
LICENSE = "GPL-2.0-or-later"
LIC_FILES_CHKSUM = "file://COPYING;md5=b234ee4d69f5fce4486a80fdaf4a4263"

# Carried in meta-segno because no layer we use provides avrdude (#430):
# meta-openembedded/meta-oe has no such recipe on any branch, and
# meta-microcontroller — the one the OE layer index lists — is stuck on
# hardknott, four series behind walnascar.
SRC_URI = "https://github.com/avrdudes/avrdude/releases/download/v${PV}/avrdude-${PV}.tar.gz"
SRC_URI[sha256sum] = "a689d70a826e2aa91538342c46c77be1987ba5feb9f7dab2606b8dae5d2a52d5"

# The config parser is generated at build time — the release tarball ships
# src/config_gram.y and src/lexer.l, not the pre-generated C — so both tools are
# genuinely required, not conveniences.
DEPENDS = "flex-native bison-native"

inherit cmake

# Serial only, on purpose. The pedal's bootloader enumerates as a CDC ACM port,
# so avr109 needs nothing but termios: no libusb, libftdi, hidapi, libgpiod or
# libelf. Every one of those is a soft find_library() probe upstream, so leaving
# them out of DEPENDS disables them — that keeps the appliance image small and
# removes whole classes of build and runtime failure from a component whose only
# job here is to write one .hex over one serial port.
#
# The three hardware-access features are already OFF upstream; named explicitly
# so a future avrdude release flipping a default cannot quietly pull libgpiod or
# parport support into the image.
EXTRA_OECMAKE = " \
    -DBUILD_DOC=OFF \
    -DHAVE_LINUXGPIO=OFF \
    -DHAVE_LINUXSPI=OFF \
    -DHAVE_PARPORT=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_SWIG=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_Python3=TRUE \
"

# The flex/bison-generated parser (config_gram.c, lexer.c) carries absolute
# build paths in its #line directives, which trips the `buildpaths` QA check
# when they are copied into the debug-source package. Scoped to `-src` on
# purpose: that package is never installed on the appliance (only ${PN} is), so
# the embedded paths reach nothing shippable — and keeping the check active on
# every other package means a real buildpath leak still fails the build.
INSANE_SKIP:${PN}-src = "buildpaths"

do_install:append() {
    # elf2tag is a bash script for AVR ELF workflows we do not use. Shipping it
    # would make the image RDEPEND on bash purely for a helper nothing calls.
    rm -f ${D}${bindir}/elf2tag
}

# avrdude.conf (the programmer/part database) is not optional — avrdude exits
# without it, so it belongs in the runtime package, not in -dev.
FILES:${PN} += "${sysconfdir}/avrdude.conf"
