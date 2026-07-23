# Tier 3a — minimal Yocto/weston image running the prebuilt GTK bundle

Scaffold for the **Tier 3a spike** ([#284](https://github.com/tomassasovsky/loopy/issues/284),
child of #271): build a lean Yocto image for a **Raspberry Pi 4** that runs the
**exact** aarch64 Flutter GTK bundle validated on Tier 2 (Pi OS), under **weston**,
and measure boot-to-interactive. Plan: [`docs/plan/2026-07-23-spike-tier3a-yocto-gtk-plan.md`](../../docs/plan/2026-07-23-spike-tier3a-yocto-gtk-plan.md).

> **UNTESTED SCAFFOLD.** These recipes encode the research decisions but have **not**
> been run through a Yocto build or booted on hardware — the whole spike is
> `blocked-verify`. Expect to iterate the recipes on the build host. The likely
> first snag is **ABI matching** (our prebuilt GTK3/Mesa embedder vs the image's
> libs) — `ldd /opt/loopy/loopy` on the device is the moment of truth.

## What's here

```
kas-loopy-rpi4.yml          kas project: poky + meta-openembedded + meta-raspberrypi (walnascar), MACHINE=raspberrypi4-64
meta-loopy/
  conf/layer.conf
  recipes-core/images/loopy-kiosk-image.bb          core-image-weston + our bundle + GTK3/Mesa/ALSA
  recipes-loopy/loopy-bundle/loopy-bundle.bb         install the PREBUILT bundle (no source build) + launcher + systemd unit
  recipes-graphics/weston-init/weston-init.bbappend  weston.ini: kiosk-shell + dual HDMI outputs
```

**No meta-flutter** — it has no GTK embedder (that's what 3b/ivi-homescreen is for).
3a is a stock weston image plus our prebuilt bundle. **ALSA-only** (no PipeWire/JACK
→ no `pw-jack` needed; the engine falls straight to ALSA).

## Build (from an Apple-Silicon Mac)

Needs Docker Desktop (or colima/podman). Give the VM **≥120 GB disk, ≥16 GB RAM, 4–6
cores**. First build is **~2–5 h**.

1. **Build the aarch64 bundle** and stage it where the container can see it (under the
   repo, so kas's mount picks it up):
   ```bash
   deploy/rpi/build/build-arm64-bundle.sh
   mkdir -p deploy/yocto/prebuilt
   cp -a build/linux/arm64/release/bundle deploy/yocto/prebuilt/bundle
   ```
   (`deploy/yocto/prebuilt/` is gitignored — it's a 26 MB binary artifact.)

2. **Get `kas-container`** (Siemens' image runs **native arm64** on Apple Silicon —
   do **not** use crops/poky, which is amd64-only):
   ```bash
   curl -O https://raw.githubusercontent.com/siemens/kas/master/kas-container
   chmod +x kas-container
   ```

3. **Build:**
   ```bash
   ./kas-container build deploy/yocto/kas-loopy-rpi4.yml
   ```
   Keep BitBake's `tmp/`/`sstate`/`downloads` **off** any `/Users` bind mount
   (VirtioFS is a perf cliff); kas-container's default in-container build dir is fine.

4. **Flash** the `.wic.bz2` (from `build/tmp/deploy/images/raspberrypi4-64/`) — Etcher
   has a bug where compressed `.wic.bz2` yields an **unbootable** card, so **decompress
   first**:
   ```bash
   bunzip2 -k loopy-kiosk-image-*.wic.bz2
   diskutil list                      # find the SD, e.g. /dev/disk4
   diskutil unmountDisk /dev/disk4
   sudo dd if=loopy-kiosk-image-*.wic of=/dev/rdisk4 bs=4m
   ```
   (or `bmaptool copy --bmap image.wic.bmap image.wic.bz2 /dev/rdisk4`.)

5. **Boot on the Pi 4** and validate (see the plan's Phase 5). Iterate app-only
   changes by `rsync`-ing the bundle to `/opt/loopy` on the running Pi instead of
   reflashing.

## When to bail to a cloud builder

The local container route usually works, but two things can make it painful:
**arm64-host recipe breakage** (any vendor layer shipping prebuilt x86_64 host
binaries) and the **Docker-on-macOS filesystem tax**. If either costs more than it
saves, build on a **cloud/native x86_64 Linux** host — the reference arch Yocto/
meta-raspberrypi/meta-flutter CI validate against.
