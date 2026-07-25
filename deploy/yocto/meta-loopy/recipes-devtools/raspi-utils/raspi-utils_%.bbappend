# The RAUC RPi custom bootloader backend (bootloader-custom-backend) flips the
# tryboot one-shot flag through `vcmailbox` (the VideoCore mailbox CLI). The base
# meta-raspberrypi raspi-utils recipe only compiles pinctrl + dtmerge:
#
#     OECMAKE_TARGET_COMPILE = "pinctrl/all dtmerge/all"
#     OECMAKE_TARGET_INSTALL = "pinctrl/install dtmerge/install"
#
# so `vcmailbox` never lands in the image and RAUC slot activation dies with
# "vcmailbox: command not found" (child exit 127) at the final "marking slot
# bootable" step. Build + install the vcmailbox target too. It's a standalone C
# program (mailbox ioctl, no extra DEPENDS) with its own install() rule, exactly
# parallel to pinctrl/dtmerge.
OECMAKE_TARGET_COMPILE:append = " vcmailbox/all"
OECMAKE_TARGET_INSTALL:append = " vcmailbox/install"
