# feat: appliance `/data` grow-to-fill (OTA-deliverable)

Closes tracking: [#346](https://github.com/tomassasovsky/loopy/issues/346).

## Problem

[`loopy-tryboot.wks`](../../deploy/yocto/meta-loopy/wic/loopy-tryboot.wks) seeds
`p7` (`/data`) at 2 GiB. On a 128 GB card ~110 GB stays unpartitioned, so a
single 96 kHz performance export can fill `/data` and fail mid-write.

## Approach

- Keep the 2 GiB WIC seed (small flashable image).
- Ship `loopy-data-grow` (systemd oneshot) that grows MBR extended `p4` then
  logical `p7` to 100% of the disk and runs `resize2fs`.
- Deliver via RAUC/OTA (rootfs gains the script + `parted` /
  `e2fsprogs-resize2fs`). No reflash required for existing cards.

## Files

- `deploy/yocto/meta-loopy/recipes-loopy/loopy-bundle/files/loopy-data-grow`
- `deploy/yocto/meta-loopy/recipes-loopy/loopy-bundle/files/loopy-data-grow.service`
- `loopy-bundle.bb` wiring + RDEPENDS
- `docs/RUNNING_ON_RPI.md` note

## Verify (on device)

```bash
df -h /data
journalctl -u loopy-data-grow.service -b --no-pager
```

Expect `/data` near card capacity after first boot/OTA onto a larger SD. Second
boot is a no-op. If the new RAUC slot does not stick, see #307
(`rauc status mark-good booted`).
