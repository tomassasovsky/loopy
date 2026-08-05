# feat: appliance `/data` grow-to-fill (OTA-deliverable)

Closes tracking: [#346](https://github.com/tomassasovsky/segno/issues/346).

## Problem

[`segno-tryboot.wks`](../../deploy/yocto/meta-segno/wic/segno-tryboot.wks) seeds
`p7` (`/data`) at 2 GiB. On a 128 GB card ~110 GB stays unpartitioned, so a
single 96 kHz performance export can fill `/data` and fail mid-write.

## Approach

- Keep the 2 GiB WIC seed (small flashable image).
- Ship `segno-data-grow` (systemd oneshot) that grows MBR extended `p4` then
  logical `p7` to 100% of the disk and runs `resize2fs`.
- Deliver via RAUC/OTA (rootfs gains the script + `parted` /
  `e2fsprogs-resize2fs`). No reflash required for existing cards.

## Files

- `deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-data-grow`
- `deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-data-grow.service`
- `segno-bundle.bb` wiring + RDEPENDS
- `docs/RUNNING_ON_RPI.md` note

## Verify (on device)

```bash
df -h /data
journalctl -u segno-data-grow.service -b --no-pager
```

Expect `/data` near card capacity after first boot/OTA onto a larger SD. Second
boot is a no-op. If the new RAUC slot does not stick, see #307
(`rauc status mark-good booted`).
