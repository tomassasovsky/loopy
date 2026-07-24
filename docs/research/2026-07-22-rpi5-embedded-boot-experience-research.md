# Running Loopy as an embedded appliance on a Raspberry Pi 5

**Research spike — 2026-07-22.** Goal: turn the Pi 5 floor-console into a true
appliance — **fast boot, a Flutter splash animation, and no desktop ever
appearing at any point**, just Loopy. This builds on the floor-console software
already shipped (PRs #86–#93: GTK-on-Wayland + labwc + systemd kiosk, dual
display pinning, power-cut resilience). It does **not** revisit those decisions;
it fills the three gaps they left open: the *boot experience*.

## TL;DR

- **Keep the committed stack**: Flutter Linux/GTK runner under **labwc** on
  Wayland, launched by systemd. `flutter-pi` and `cage` are still ruled out —
  both break the waveform second window (dual-display) the same way flutter-pi
  did in Part 1. Nothing here needs changing that.
- **The "no desktop" goal is 90% already met** — the kiosk boots straight into
  the app; there is no desktop environment installed. What's left is killing the
  *visual seams* during boot (rainbow splash, kernel text, a compositor grey/
  black flash before the first Flutter frame).
- **Flutter has no native Linux splash mechanism** (`flutter_native_splash`
  supports Android/iOS/web only). So the "splash animation" is **two cooperating
  layers**: a **Plymouth** boot splash covering firmware→app-launch, handed off
  **seamlessly** to an **in-app animated Flutter splash** that plays while the
  audio engine opens the interface.
- **The single most important hook already exists**: the runner only shows its
  window on Flutter's *first frame* (`first_frame_cb`,
  [`my_application.cc:19`](../../linux/runner/my_application.cc)). That's the
  exact signal to quit Plymouth with `--retain-splash`, giving a zero-gap
  handoff. This is the linchpin of a flash-free boot.
- **Realistic boot target**: ~30 s stock Pi OS Desktop → **8–12 s to first
  Flutter frame** on Pi OS Lite + NVMe with a service diet; the *perceived*
  boot is shorter still because Plymouth+splash cover the whole time.

---

## 1. The boot chain today, and where the flashes are

On a Pi 5 the visual pipeline from power-on to a running app has five seams,
each a potential flash of the wrong thing:

| # | Stage | Default visual | Appliance wants |
|---|-------|----------------|-----------------|
| 1 | Pi firmware / bootloader | Rainbow test pattern, then Pi logo(s) | Nothing (black or splash) |
| 2 | Kernel + early userspace | Scrolling white-on-black boot text, blinking cursor | Nothing |
| 3 | Plymouth (if installed) | *Not installed by default on Lite* | Branded splash, from as early as KMS allows |
| 4 | Compositor start (labwc) | Grey/black compositor background before any window | Splash still visible — no grey flash |
| 5 | App launch → first frame | Empty window / black until Flutter renders | Splash still visible → dissolve into app |

The existing `deploy/rpi/` kiosk handles *program* flow (labwc autostarts, app
launches, respawns on crash) but does nothing about seams 1, 2, 4, 5 — so today
a cold boot would show rainbow → kernel text → a grey labwc flash → black → app.
The work below closes each seam.

---

## 2. No desktop, no flashes — the visual pipeline

### 2.1 Kill firmware + kernel chatter (seams 1–2)

All in the Pi 5 firmware config (note the Pi 5 paths under `/boot/firmware/`):

`/boot/firmware/config.txt`:
```ini
disable_splash=1        # no rainbow test pattern
```

`/boot/firmware/cmdline.txt` (single line — append these tokens):
```
quiet loglevel=0 logo.nologo vt.global_cursor_default=0 consoleblank=0 plymouth.ignore-serial-consoles
```
- `quiet loglevel=0` — suppress kernel/service boot messages.
- `logo.nologo` — remove the raspberry logos.
- `vt.global_cursor_default=0` — no blinking text cursor.
- `consoleblank=0` — never blank the console (an always-on stage unit must not
  DPMS-sleep mid-set; also set screen-blanking off in the compositor).

This alone removes seams 1–2. What remains between "kernel handed off" and "app
drawn" is a black screen — which Plymouth then paints over.

### 2.2 Plymouth for seams 3–4 (boot splash)

Pi OS Lite does not ship Plymouth; install it plus a theme. Add `splash` to
`cmdline.txt` to enable it. Plymouth relies on **KMS** to grab the framebuffer
at native resolution very early, so the splash appears almost immediately after
firmware and *stays up through kernel, systemd, and compositor start* — covering
seam 4 (the labwc grey flash) as long as we don't let Plymouth quit too early.

Key: **do not `plymouth quit` on `multi-user.target`** (the distro default).
Keep it alive until the *app* is ready (see §3.2). A `plymouth-quit.service`
ordered `After=` our kiosk, or an explicit quit from the app, is what makes the
handoff seamless.

### 2.3 Compositor: no grey flash, no cursor, no blanking

labwc's default background is a solid colour; set it to the **splash background
colour** so that even if Plymouth quits a frame early, what shows underneath the
app matches the splash instead of flashing grey/black. In `rc.xml`/theme, and:
- Hide the pointer until moved (kiosk has none): labwc `<core><cursor>` / start
  with no cursor theme, or `unclutter`-equivalent.
- Disable screen blanking / DPMS in the compositor for an always-on unit.

`cage` (single-window kiosk compositor) would give a slightly simpler "one app,
fullscreen, no chrome" story, **but** it is single-window and would break the
`desktop_multi_window` waveform panel — the same disqualifier as flutter-pi in
Part 1. Stay on labwc.

### 2.4 Autologin / seat

The current unit takes tty1 with `PAMName=login` and conflicts `getty@tty1`.
That works; an alternative is `greetd` with auto-session (what the TOLDOTECHNIK
Pi-5 kiosk uses). Either is fine — the systemd-direct approach we already have is
one fewer moving part and one fewer package. Keep it unless greetd buys us
something (it doesn't here). Booting the compositor from an **earlier target**
than `multi-user.target` is a bigger boot-time lever (see §4).

---

## 3. The Flutter splash animation

### 3.1 There is no native Linux splash — so it's an in-app screen

`flutter_native_splash` (the usual "splash while the engine boots" package)
**does not support Linux desktop** — Android/iOS/web only. On Linux the first
thing the user can see from Flutter is whatever the first route renders. So the
"Flutter splash animation" is a real Flutter widget: an animated logo screen
that is the app's initial screen, shown while:
- the audio engine opens and pins the USB interface (the
  `AudioRecoveryCubit` / `audio_bootstrap` path from Part 7 already models "not
  ready yet" — the splash is its natural visual), and
- the waveform second window opens on the 7″.

When the engine is up and `BigPictureView` is ready, the splash animation
completes / dissolves into the main UI. This doubles as honest UX: the appliance
genuinely isn't ready to loop until the interface is open, and the animation
covers exactly that interval instead of showing a dead UI.

### 3.2 The seamless handoff — the one hook that matters

The runner already **only shows the GTK window on Flutter's first frame**:

```c
// my_application.cc:19
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}
```

That is precisely the moment to tear down Plymouth with **`plymouth quit
--retain-splash`**, so the boot splash stays painted on the framebuffer until —
and only until — the app has a real frame to show. Sketch:

```c
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  // Hand off: keep the boot splash on-screen until our first frame exists,
  // then dismiss it. --retain-splash avoids a black frame during the swap.
  g_spawn_command_line_async("plymouth quit --retain-splash", nullptr);
}
```

Result: firmware → Plymouth splash → (kernel/systemd/labwc all happen *behind*
the splash) → Loopy's first frame is drawn → Plymouth quits → the in-app splash
animation is already on screen. **No black gap, no grey compositor flash, no
desktop, ever.** If the Plymouth splash's final image and the Flutter splash's
first frame share the same logo + background colour, the transition reads as one
continuous animation.

Belt-and-suspenders: set the GTK view background (currently `#000000`,
[`my_application.cc`](../../linux/runner/my_application.cc)) and the labwc
background to the splash background colour, so any 1-frame mismatch is invisible.

### 3.3 Optional: animated Plymouth theme

Plymouth themes can be scripted (the `script` module) for an animated boot
splash, not just a static PNG — so the motion can start *before* Flutter is even
loaded and continue into the app. This is polish; a static splash that matches
the Flutter splash's first frame already gives a flash-free result. Decide based
on how much boot-time branding is wanted.

---

## 4. Fast boot

Perceived boot is already hidden by the splash; this section is about *actual*
time-to-first-frame. Stock Pi OS Desktop is ~30 s; the achievable target on this
appliance is **~8–12 s**, dominated by storage and the service set.

**Biggest levers, in order:**

1. **Pi OS Lite, not Desktop.** No LXDE/labwc-desktop, no piwiz, no
   NetworkManager applet, no display-manager. Lite runs roughly half the
   processes of Desktop. We install *only* labwc + the app + audio stack. This is
   the single biggest structural win and it also *is* the "no desktop" guarantee
   — the desktop packages are simply never installed.
2. **NVMe over microSD.** Pi 5 has a PCIe lane (NVMe HAT / Pi 5 M.2). microSD
   tops out ~60–90 MB/s random-heavy; NVMe does 400–900 MB/s. Boot I/O is the
   long pole once services are trimmed — this can halve time-to-app. Strongly
   recommended for a product-feel appliance; the read-only-root overlay from
   Part 6 works the same on NVMe.
3. **Service diet.** `systemd-analyze blame` / `systemd-analyze critical-chain`
   on the real image, then `systemctl disable` what a standalone looper doesn't
   need. Usual suspects: `NetworkManager-wait-online` / `systemd-networkd-wait-online`
   (disable the *wait*, seconds saved), `ModemManager`, `bluetooth` (unless the
   pedal/LED path needs it — it doesn't, LED is UART, pedals are GPIO/USB),
   `avahi-daemon`, `triggerhappy`, `cups`, `dphys-swapfile`, `raspi-config`
   first-boot, `apt-daily*` timers. If the console is truly offline, WiFi can go
   too (keep a documented way to re-enable for updates).
4. **Start the compositor earlier.** The kiosk unit is `After=multi-user.target`,
   which waits for the full normal boot. Ordering it after a lighter target (or
   just `systemd-user-sessions.service` + the writable-data mount it truly needs)
   lets the UI come up before the last stragglers. Trade-off: don't race the
   data-partition mount / boot-integrity check from Part 6 — those are real
   `ExecStartPre` deps and must stay ordered before the app.
5. **Firmware/bootloader**: `boot_delay=0` in config.txt; set the Pi 5 EEPROM
   `BOOT_ORDER` to go straight to the boot medium (NVMe or SD) without probing
   USB/network first (`rpi-eeprom-config`); `initial_turbo` for the first
   seconds of CPU clock. Smaller wins than 1–3 but free.
6. **Filesystem**: F2FS is flash-optimised (instant-pi uses it), but ext4 on
   NVMe is already fast and better-trodden on Pi OS; not worth the divergence
   unless boot time is still short after 1–4. Read-only overlay root (Part 6)
   should be measured for its (small) boot cost.

**Method**: bring the image up, run `systemd-analyze blame` on the *actual*
appliance, and cut against data — don't disable blind. Record the before/after
in `docs/RUNNING_ON_RPI.md`.

### 4.1 Perceived boot ≠ time-to-app — chase the first one

The number that makes boot "feel long" is **time to the first branded pixel**,
not time-to-interactive. These decouple:

- **Time to Plymouth splash** — Plymouth grabs the framebuffer via KMS very early
  in the kernel, so a branded splash can be on screen in **~1–2 s** from power-on,
  regardless of when the app is ready. This is the number the user actually feels.
- **Time to first *Flutter* frame** — the in-app splash. Make this cheap: the
  first route must be the animated splash and **nothing else**. Do *not* block the
  first frame on the audio engine opening — kick engine init off *after* first
  frame (async), so the Flutter splash appears the moment the engine library +
  Skia are loaded (~1–2 s after the compositor), not after the USB interface opens.
- **Time to interactive** (engine open, loops armable) — the slow one, but it's
  hidden *behind the splash animation*, so its length stops mattering for feel.

So the design rule: **decouple first-frame from engine-ready**. The Plymouth→
Flutter-splash chain gives a continuous branded animation from ~1–2 s onward; the
8–12 s only governs when the animation can dissolve into a live UI. Someone
powering on before a set never stares at a blank screen.

### 4.2 How low can time-to-interactive actually go? (tiers)

| Tier | Approach | Time-to-app | Cost |
|------|----------|-------------|------|
| Stock | Pi OS Desktop, microSD | ~20–45 s | — |
| **1** | Pi OS Lite + NVMe + service diet + earlier compositor target | **~6–10 s** | Config only; recommended baseline |
| **2** | Tier 1 + EEPROM `BOOT_ORDER` NVMe-only + `USB_MSD_DISCOVER_TIMEOUT` cut + **drop the initramfs** (root modules built-in) + no `*-wait-online` + mild overclock | **~5–7 s** | More config + testing; still Pi OS |
| **3** | **Buildroot/Yocto** custom image: stripped kernel (only needed drivers built-in), minimal init, only the packages the app needs | **~2–4 s** | Big — rebuild the whole OS image, cross-compile Flutter + engine + GTK/labwc against Buildroot, lose apt/Pi-OS convenience, own kernel maintenance |

**Tier-2 firmware/bootloader specifics** (Pi 5):
- EEPROM (`rpi-eeprom-config`): `BOOT_ORDER=0x6` (NVMe only — stop probing SD/
  USB/network); `USB_MSD_DISCOVER_TIMEOUT` low if any USB in the order; `BOOT_UART=0`.
- `config.txt`: `boot_delay=0`, `dtparam=pciex1_gen=3` (full NVMe speed),
  `disable_poe_fan`, drop unused `dtoverlay`s.
- **Initramfs removal** is the biggest Tier-2 kernel lever: Pi OS boots through an
  initramfs by default; with the root-fs + NVMe drivers built into the kernel you
  can boot without it (`initramfs` line removed, `auto_initramfs=0`), saving load+
  decompress+pivot time. Requires a kernel that has those drivers built-in — easy
  in Buildroot, fiddlier on stock Pi OS.

**The honest floor**: Debian + systemd + Pi firmware realistically bottoms out
around **5–6 s to interactive**. Going meaningfully below that means leaving Pi OS
for **Buildroot/Yocto** (Tier 3) — the real "embedded appliance" path (a webradio
Buildroot Pi reaches the app ~2 s after kernel, vs 100 s on Pi OS Lite for the
same app, because Lite still starts dozens of services). For a looper you power on
before a set, Tier 2 (~5–7 s to interactive, ~1–2 s to splash) is almost
certainly enough; Tier 3 is a large, separate commitment to justify only if a
cold-to-playable time under ~4 s is a hard product requirement.

---

### 4.3 Tier 3 deep-dive: Yocto / meta-flutter (the real appliance path)

Tier 3 is a genuine option, but "Buildroot/Yocto" resolves to a specific stack
and a specific fork once you look at *this* app.

**It's Yocto + `meta-flutter`, not raw Buildroot.** For Flutter specifically the
maintained embedded path is the **`meta-flutter`** Yocto layer (engine + embedder
recipes, channel rolling), riding **`meta-raspberrypi`**. Caveats:
- meta-flutter's tested machines are Pi 3/4/Zero2W; **Pi 5 is aarch64 and has a
  `raspberrypi5` machine in meta-raspberrypi, but is slightly off meta-flutter's
  validated set** — expect some bring-up.
- Heavy build: initial source fetch alone is **14 GB+**; you own kernel + image
  maintenance and a Yocto build host. This is the real cost of Tier 3, not the
  runtime.

**The fork that decides everything: the 7″ waveform panel.** meta-flutter's
blessed *on-device* embedders are **ivi-homescreen / flutter-auto** (Wayland,
single-engine); GTK is positioned as a *host-dev* validation embedder. And our
second window is hard-coupled to the GTK embedder — confirmed in-code:
`desktop_multi_window` + `window_manager` + `screen_retriever_linux` are all
registered in [`linux/runner/`](../../linux/runner/my_application.cc) (the object
is a `GtkApplication`), and `desktop_multi_window` on Linux is GTK-only (each
window is its own engine via platform channels). It cannot run on
ivi-homescreen or flutter-pi. So:

- **Tier 3a — Yocto + GTK embedder.** Keeps the separate 7″ waveform panel and
  *all* current code unchanged, but off meta-flutter's happy path: build GTK3 +
  labwc into a custom image and drop the standard `flutter build linux` bundle in.
  GTK3's dependency tree erodes some of the size/boot win. Realistic ~3–5 s.
- **Tier 3b — Yocto + ivi-homescreen.** Leanest, fastest (~2–4 s), on the
  supported path. `desktop_multi_window` doesn't work here — **but the physically
  separate 7″ display is still achievable**, via ivi-homescreen's *native*
  multi-view (see §4.3.1). The painter
  [`WaveformView`](../../lib/visualizer/widgets/waveform_view.dart) is already
  embedder-agnostic (imports only `material` + theme, and is *already* reused in
  the pedal faceplate and main visualizer), so it drops straight into a second
  ivi view. What changes is the *plumbing*, not the feature.

#### 4.3.1 Keeping the second physical display on Tier 3 (the multi-window answer)

The requirement is **two rendering surfaces on two outputs sharing engine state** —
that is *not* the same as needing the `desktop_multi_window` plugin. Three ways
to get it on an embedded stack, best first:

1. **ivi-homescreen native multi-view (recommended for 3b).** ivi-homescreen
   takes multiple `-b <bundle>` flags → **one view per flag, each its own Flutter
   engine**, and each view targets a specific display via an **`output_index`**
   parameter (per-view `pixel_ratio` too). So: main UI view on the 16″
   (output 0), a second view running just `WaveformView` on the 7″ (output 1) —
   the same engine-per-window model as today, expressed in the embedder config
   instead of via a Flutter plugin. It runs under a Wayland compositor
   (labwc/weston owns DRM and exposes both outputs), or as its own compositor with
   `-DBUILD_COMPOSITOR=ON`.
   - **State sharing gets *simpler*, not harder.** Both views live in one
     ivi-homescreen process, so they share the single loaded `libloopy_engine.so`
     and its process-global engine state. The waveform view's isolate can **pull
     frames directly from the engine via FFI** (`readWaveform()`) instead of
     today's push-over-method-channel from the main window. That deletes the
     `desktop_multi_window` + `window_manager` + `screen_retriever_linux`
     dependencies outright.
   - **Bounded new work**: a second Dart entrypoint that mounts `WaveformView` +
     reads the engine; ivi launch config with two `-b` + `output_index`; and
     confirming `readWaveform()` is safe to call from a second isolate (the audio
     thread already produces the waveform buffer — verify the read path is
     lock-free / snapshot-based). Replaces `WaveformWindowService`.
2. **Two embedder processes, one per display — avoid on Pi.** Running two
   flutter-pi instances (one per connector) hits DRM/KMS master contention: KMS
   won't let two independent processes each own a connector without **DRM
   leasing**, which is fragile on the Pi. A Wayland compositor exists precisely to
   own DRM and hand each output to a client — so prefer option 1 over this.
3. **Tier 3a — GTK embedder — keeps `desktop_multi_window` verbatim.** Zero
   Dart/plugin changes; the cost is the heavier embedder and ~3–5 s instead of
   ~2–4 s. This is the fallback if the option-1 port is deemed not worth it.

**Bottom line for a hard multi-window requirement**: it does **not** force Tier 3a.
Tier 3b keeps the separate 7″ panel via ivi multi-view (option 1); the port is
moderate and well-bounded and actually *removes* three Linux plugins. Choose 3a
only to avoid touching the waveform launch path at all.

*Forward-looking note*: Flutter's official framework-level multi-window support
(the Canonical/Ubuntu effort) is maturing; if it reaches the embedder API it
could make this portable across embedders later. Not a foundation to plan on
today — treat ivi multi-view as the concrete path.

**Audio on a pure-ALSA image: not a risk — arguably better.** Confirmed in-code:
miniaudio compiles all backends (no `MA_NO_*` for devices,
[`miniaudio_impl.c:10`](../../packages/loopy_engine/src/miniaudio/miniaudio_impl.c)),
Linux hands it an ordered list `{jack, pulseaudio, alsa}`
([`engine_linux.c:213`](../../packages/loopy_engine/src/platform/engine_linux.c))
and takes the first that initializes — with no JACK/Pulse present it **degrades
cleanly to ALSA**. The JACK port-pinning / monitor-skip logic no-ops off the JACK
backend (`engine_linux.c:157`), and the PipeWire-quantum poking is best-effort
(`pw-metadata` simply absent). The only hard native dep is **libasound** (present
in any ALSA image); the `system()` calls need **`/bin/sh`** in the image (trivial
to include). Bonus: the JACK/PipeWire headaches from
[`RUNNING_ON_LINUX.md`](../RUNNING_ON_LINUX.md) (buffer stuck at server quantum,
generic device name, aggregate auto-connect) **disappear** on ALSA — miniaudio
honors the requested period directly. Net: Tier 3 *improves* audio determinism.

**Everything else is portable C, already `blocked-verify` on Yocto:** `gpio_client`
(libgpiod), `led_client` (termios/serial), MIDI (ALSA-seq, links libasound) — all
standard Yocto packages. And **read-only root is native in Yocto**
(`read-only-rootfs` image feature) — cleaner than the Pi OS overlay hack from
Part 6.

**Recommendation.** If Tier 3 is chosen, prefer **3b** (ivi-homescreen, drop
`desktop_multi_window`, reuse `WaveformView` in-app or via an ivi second view):
it's the fastest, is on meta-flutter's supported path, and the one feature it
costs — the separate waveform window — is cheap to re-provide because the painter
is already decoupled. **3a** only makes sense if preserving the exact current
two-OS-window architecture unchanged outweighs the fastest boot. The dominant
Tier-3 cost is not runtime or our code — it's owning a Yocto image + Pi-5 bring-up
on meta-flutter. Justify that only if cold-to-playable **under ~4 s** is a hard
product requirement; otherwise Tier 2 (~5–7 s, config-only, zero re-arch) wins.

## 5. What to add to the repo (concrete, builds on `deploy/rpi/`)

Nothing here rewrites the shipped kiosk; it adds the boot-experience layer:

- **`deploy/rpi/boot/config.txt` + `cmdline.txt` fragments** (or a documented
  patch) with the §2.1 flags. These are image-level, so ship them as
  copy-in fragments + README steps, like the existing systemd/labwc files.
- **`deploy/rpi/plymouth/`** — a Loopy theme (static PNG matching the Flutter
  splash's first frame, or a scripted animation) + install steps + the "don't
  quit Plymouth until the app is up" ordering (a drop-in that neutralises the
  default `plymouth-quit-wait` or orders it after the kiosk).
- **Runner change** — add the `plymouth quit --retain-splash` spawn to
  `first_frame_cb` in `my_application.cc` (guard it so it's a no-op when
  Plymouth isn't running, e.g. on a dev desktop — check exit status / gate on an
  env var like `LOOPY_KIOSK=1` so `flutter run` on a laptop is unaffected).
- **In-app splash screen** — an animated splash route shown until the engine is
  ready, wired to the existing `audio_bootstrap` / `AudioRecoveryCubit` "ready"
  signal. Themed with `LooperTheme` tokens (no pixel literals — VGV standard).
  Set the GTK view + labwc background to the splash colour.
- **labwc**: set background colour = splash colour, hide cursor, disable
  blanking (append to the existing `rc.xml` / autostart).
- **`docs/RUNNING_ON_RPI.md`**: a "Boot experience" section + boot-time
  before/after table + the on-device seam checklist (cold boot shows *no*
  rainbow / no text / no grey flash / no black gap; `systemd-analyze` figure).

---

## 6. Open decisions (need a human call)

0. **OS tier: Tier 2 (Pi OS) vs Tier 3 (Yocto/meta-flutter)** — the top fork.
   Tier 2 is config-only, ~5–7 s, zero re-arch. Tier 3 is ~2–4 s but a whole-OS
   commitment; **if Tier 3, then 3a (GTK, keep the separate waveform window) vs
   3b (ivi-homescreen, reuse `WaveformView` in-app)** — recommend 3b (§4.3).
1. **NVMe vs microSD** for the shipping unit — cost/BOM + enclosure vs a real
   boot-time and durability win. Affects `hardware/loopy_console_shopping_list.md`.
2. **Plymouth splash: static or scripted-animated?** Static already gets a
   flash-free result; animated is pure branding polish.
3. **How much service-trimming** — a fully offline appliance boots fastest but
   loses in-field updates/SSH. Recommend keeping WiFi+SSH but disabling the
   *wait-online* and the obvious dead weight (§4.3), i.e. fast boot without
   painting ourselves into an un-updatable corner.
4. **Splash art** — needs a Loopy mark / animation (shared by Plymouth + the
   Flutter splash so the handoff is invisible).

## 7. Suggested phasing (if this becomes a plan)

- **P1 — silent boot**: config.txt/cmdline.txt flags + Pi OS Lite baseline; kill
  seams 1–2. Cheap, high-impact, no art needed. *(verifiable on device only)*
- **P2 — Plymouth + seamless handoff**: theme + `first_frame_cb` retain-splash +
  compositor background colour. Kills seams 3–5. Needs splash art.
- **P3 — in-app Flutter splash animation**: the animated route + engine-ready
  wiring. Testable in widget tests (unlike the boot seams).
- **P4 — fast-boot pass**: NVMe + `systemd-analyze`-driven service diet +
  earlier compositor target; record before/after.

All boot-seam work is **on-device-verifiable only** (no display/audio in CI) —
same `blocked-verify` posture as the rest of the console. P3 (the Flutter splash)
is the one piece with real CI-testable coverage.

---

### Sources
- [Raspberry Pi 5 kiosk on Bookworm Lite (2025) — RPi Forums](https://forums.raspberrypi.com/viewtopic.php?t=389880)
- [TOLDOTECHNIK Raspberry-Pi-Kiosk-Display-System (labwc + greetd + Plymouth)](https://github.com/TOLDOTECHNIK/Raspberry-Pi-Kiosk-Display-System)
- [instant-pi — fastest-boot techniques (F2FS, cut-down kernel, LZ4)](https://github.com/IronOxidizer/instant-pi)
- [Plymouth — ArchWiki (KMS, flicker-free, ShowDelay)](https://wiki.archlinux.org/title/Plymouth)
- [Seamless boot on Wayland — Arch Forums](https://bbs.archlinux.org/viewtopic.php?id=295767)
- [Silent boot / hiding Pi boot text (cmdline flags)](https://forums.raspberrypi.com/viewtopic.php?t=289602)
- [Disabling the Pi5 welcome/splash — RPi Forums](https://forums.raspberrypi.com/viewtopic.php?t=379364)
- [Raspberry Pi boot-time optimization guide](https://ohyaan.github.io/tips/raspberry_pi_boot_time_optimization__complete_performance_guide/)
</content>
</invoke>
