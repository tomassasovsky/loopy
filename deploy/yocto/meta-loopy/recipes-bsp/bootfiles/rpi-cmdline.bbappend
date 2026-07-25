# A/B tryboot: ship cmdline.txt with a "root=XXX" placeholder in BOTH boot slots.
# tryboot-cmdline.bbclass rewrites it per-slot inside the .wic after do_image_wic
# (bootA -> root=/dev/mmcblk0p5, bootB -> root=/dev/mmcblk0p6).
CMDLINE_ROOT_PARTITION = "XXX"
