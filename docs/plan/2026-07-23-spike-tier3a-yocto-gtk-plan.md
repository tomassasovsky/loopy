---
title: "Tier 3a spike: minimal Yocto image running the prebuilt Flutter GTK bundle (Pi 4B → Pi 5)"
type: spike
date: 2026-07-23
---

## Tier 3a spike: minimal Yocto image running the prebuilt Flutter GTK bundle - Standard

Issue: #284 (child of direction issue #271) · Research: `docs/research/2026-07-22-rpi5-embedded-boot-experience-research.md` §4.3 · Builds on the Tier 2 bring-up validated on real hardware (Pi 4B) in this session.

> Grounded by two research passes (2026-07-23): (1) meta-flutter feasibility — **it has no GTK embedder**, so 3a does not use meta-flutter; (2) Yocto-on-Apple-Silicon build infra — **kas-container runs native arm64**, crops/poky does not.

## Overview

Prove the **existing Flutter GTK floor-console bundle** — the exact `arm64` bundle
validated tonight on Tier 2 (Pi OS + labwc) — runs **unmodified on a minimal
Yocto/weston image** on a **Pi 4B**, built from the Apple-Silicon Mac via
`kas-container`, and **measure boot-to-interactive versus Tier 2**. This answers
the only question that matters for the Tier 2-vs-3 decision in #271: *does our
current binary run on a lean appliance OS, and is the boot meaningfully faster,
without touching app code?*

**This is a spike, not a product image.** Success = "it boots, runs, plays audio,
drives both displays, and here is the boot-time delta." It deliberately does **not**
port to a new embedder (that is 3b), target the Pi 5, or build a production
(OTA/read-only-root) image.

## Key finding that shapes the approach

meta-flutter builds only the *embedded* embedders (ivi-homescreen, flutter-auto) —
**there is no GTK-desktop-embedder target**. So "3a via meta-flutter" is a
misconception. The feasible mechanism is a **stock `core-image-weston`** (which
already ships weston + GTK3) plus our **prebuilt bundle packaged by a trivial
install recipe**, run as a **Wayland client under weston's kiosk-shell**. meta-flutter
is not in the layer stack for 3a. (It *is* where 3b lives — see Non-Goals.)

The real risk is therefore **not the Flutter version** (our bundle embeds its own
3.44.4 engine) but **ABI matching**: our prebuilt `libflutter_linux_gtk.so` +
`libloopy_engine.so` must load against the image's GTK3/glib/glibc/Mesa. That is
classic "green build ≠ runs" — a **`blocked-verify`** item proven on the Pi.

## Proposed Solution

### Phase 0 — Build host (Mac)

- **`kas-container`** on Docker Desktop (or colima/podman). Its `ghcr.io/siemens/kas`
  images are **multi-arch → native arm64** on Apple Silicon (no QEMU tax). **Do not
  use `crops/poky`** (amd64-only → emulated/broken on Apple Silicon).
- Provision the VM: **≥120 GB disk, ≥16 GB RAM, 4–6 cores**.
- **Keep `tmp/`, `sstate-cache`, `DL_DIR` off `/Users` bind mounts** (VirtioFS
  latency + xattr/hardlink quirks tank BitBake) — use a Docker named volume / the
  VM's own ext4. `kas-container` does this by default.
- **Fallback:** a cloud/native **x86_64 Linux** builder is the reference arch Yocto/
  meta-raspberrypi/meta-flutter CI validate against — switch to it the moment
  arm64-host recipe breakage or the Docker-fs tax costs more than it saves.

### Phase 1 — Yocto layer config (`kas` project file)

- Layers: **`poky` + `meta-openembedded` + `meta-raspberrypi`**, branch **`scarthgap`**
  (Weston 13, glibc 2.39). **No meta-flutter.**
- `MACHINE = "raspberrypi4-64"`.
- Enable **VC4/V3D KMS** GPU (`vc4-kms-v3d`) so GL/Wayland/Mesa work.

### Phase 2 — Kiosk image + the bundle recipe

- Base: **`core-image-weston`** (ships `weston`, `weston-init`, GTK3 runtime).
- `kiosk-image.bb`: `require` core-image-weston + `IMAGE_INSTALL:append` for
  `gtk+3`, Mesa, **`alsa-lib`/`alsa-utils`** (ALSA-only — see audio note), and the
  bundle recipe.
- **weston kiosk-shell** (`[core] shell=kiosk-shell.so` in `weston.ini` via a
  `weston-init` bbappend) — fullscreen, one app per output. Autostart the bundle as
  a Wayland client (`GDK_BACKEND=wayland`).
- **`loopy-bundle.bb` (prebuilt install recipe):** `do_install` copies the exact
  bundle tree (`loopy`, `libflutter_linux_gtk.so`, `libloopy_engine.so`, `data/`)
  into the image — **no source build**. Guard against Yocto stripping/relocating the
  AOT/native `.so` destructively (`INHIBIT_PACKAGE_STRIP`, appropriate `FILES`/
  `INSANE_SKIP` as needed). This keeps tonight's byte-identical binary.
- **Native engine deps:** enumerate what `libloopy_engine.so` needs at runtime
  (ALSA, any USB/MIDI libs) with `ldd` and add them explicitly to the image.

### Phase 3 — Audio (ALSA-only — cleaner than Tier 2)

- Ship **ALSA only, no PipeWire/JACK.** The engine's JACK→PulseAudio→ALSA fallback
  finds no libjack/libpulse in the image and lands **straight on ALSA** — so
  **no `pw-jack` shim is needed** (unlike Tier 2). Fewer moving parts, faster boot.
- Bonus to verify: with no PipeWire holding the `hw:` device, the engine may open
  the **raw multichannel ALSA device** directly (Tier 2's PipeWire path only exposed
  a 2-channel ALSA bridge). Confirm channel count on the Scarlett.

### Phase 4 — Deploy + iterate

- Output is **`.wic.bz2` + `.wic.bmap`**. **Decompress before flashing** with Etcher
  (a known bug makes compressed `.wic.bz2` produce an unbootable card), or use
  **`bmaptool copy`**. CLI: `bunzip2 -k image.wic.bz2 && sudo dd if=image.wic of=/dev/rdiskN bs=4m`.
- **Iterate app-only changes by `rsync`-ing the bundle** to the running Pi over the
  network, not reflashing.

### Phase 5 — Validation (blocked-verify, on the Pi 4B)

Single-display first, then dual-display:

1. Image boots to weston; the bundle launches fullscreen under kiosk-shell.
2. **ABI OK:** `ldd` clean on device; bundle + `libloopy_engine.so` load; app window
   appears (this is the make-or-break unknown).
3. **Audio:** Scarlett input audible; record → overdub → playback via ALSA.
4. **Dual-HDMI:** `weston.ini` `[output] name=HDMI-A-1 / HDMI-A-2` with mode + `x/y`
   placement; main UI on one output, waveform window on the second.
5. **Measure boot-to-interactive** and compare to Tier 2 (the point of the spike).

> **USB FIFO overflow will persist** (Pi 4 shared USB2 hub — OS-independent, and
> addressed on the Pi 5, not here). Not a 3a failure; out of scope.

## Success Criteria

```success-criteria
GOAL: Prove the existing Flutter GTK floor-console bundle runs unmodified on a minimal Yocto/weston image on a Pi 4B (built from the Mac via kas-container), and measure boot-to-interactive vs Tier 2 — with no app-code changes.

SUCCESS CRITERIA:
- kas-container build emits a raspberrypi4-64 core-image-weston-based image | verify: manual (build completes; .wic.bz2 + .wic.bmap produced)
- Image boots to weston on the Pi 4B | verify: manual (weston + kiosk-shell come up)
- Prebuilt bundle + libloopy_engine.so load with no missing libs (ABI OK) | verify: manual (ldd clean on device; app window renders)
- Audio works via ALSA (record/overdub/playback), no pw-jack | verify: manual (Scarlett input audible; loop plays back)
- Dual-HDMI: main UI + waveform on the two outputs via weston.ini | verify: manual (both render)
- Boot-to-interactive measured and compared to Tier 2 | verify: manual (both numbers recorded)

NON-GOALS:
- Tier 3b (ivi-homescreen embedder port + WaveformView multi-view) — separate effort, needs app code
- Pi 5 target — port after the Pi 4B spike lands
- PipeWire/JACK on the image — ALSA-only by design
- Production image: OTA/Mender, read-only root, secure boot, boot-time tuning beyond measuring the baseline
- Fixing the Pi 4 USB FIFO overflow — hardware (shared USB2 hub), OS-independent, addressed on Pi 5

VERIFICATION COMMAND: none (spike is entirely blocked-verify on hardware; no CI lane)
```

## Dependencies & Risks

- **ABI mismatch (the primary risk):** prebuilt GTK3/Mesa embedder vs the image's
  libs. Mitigation: match `scarthgap` GTK3/glibc/Mesa; if it won't load, either
  rebuild the bundle against the image SDK or treat it as a signal to jump to 3b.
  **Verify-on-device — cannot be proven by a green build.**
- **arm64-host recipe breakage:** recipes shipping prebuilt x86_64 host binaries
  (uninative tarball, some node/rust natives, vendor blobs) fail on an arm64 host.
  The weston/RPi/GTK core is fine. Mitigation: the x86_64 cloud-builder fallback.
- **Docker-on-macOS filesystem tax:** keep the build dir off `/Users`.
- **Etcher `.wic.bz2` unbootable bug:** decompress first, or use `bmaptool`.

## Tracking

`#284` is `stage:brainstorm` → this plan advances it to `stage:plan`, `autonomy:plan-gate`.
**Stop here for direction sign-off** — no Yocto build starts until the approach is
approved. Once approved, execution is `autonomy:blocked-verify` (green build ≠ works;
needs the Pi 4B on the bench). 3b (ivi-homescreen) remains a separate future issue.

## References & Research

- Research §4.3 (Tier 3 fork 3a vs 3b) — `docs/research/2026-07-22-rpi5-embedded-boot-experience-research.md`
- meta-flutter (no GTK embedder; ivi-homescreen for 3b): https://github.com/meta-flutter/meta-flutter
- kas-container (native arm64 on Apple Silicon): https://kas.readthedocs.io/en/latest/userguide/kas-container.html
- Yocto Wayland/Weston: https://docs.yoctoproject.org/scarthgap/dev-manual/wayland.html
- core-image-weston: https://github.com/openembedded/openembedded-core/blob/master/meta/recipes-graphics/images/core-image-weston.bb
- Etcher `.wic.bz2` bug: https://github.com/balena-io/etcher/issues/3138
- Tier 2 stack (what the bundle runs on today): `docs/RUNNING_ON_RPI.md`, `deploy/rpi/`
