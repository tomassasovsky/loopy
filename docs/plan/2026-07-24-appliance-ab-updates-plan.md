# Plan — Cross-platform app updates (appliance A/B + desktop auto-update)

Issue: #300 · Targets: Pi 4B appliance + Windows/macOS desktop · Autonomy: plan-gate → per-phase blocked-verify
Status: DRAFT for approval

## Goal
Keep every install current with minimal user effort, safely, without losing saved data:
- **Appliance (Pi 4B / embedded Linux):** update app + OS + kernel atomically, with
  rollback, via **tryboot A/B** (RAUC). Data on a separate partition survives updates.
- **Desktop (Windows + macOS):** automatic download + install of new app builds via the
  Flutter **`auto_updater`** plugin (Sparkle on macOS, WinSparkle on Windows), from an
  appcast feed.
- **One server, one publish pipeline:** `segno.aquiles.dev` serves the appliance bundle
  and the desktop appcasts; CI builds, signs, and uploads all artifacts on release.

## Locked decisions (from the user)
- Appliance rollback: **tryboot A/B** (Pi-native firmware; one-shot boot-attempt).
- Transports (appliance): **USB stick**, **LAN push**, **OTA pull from segno.aquiles.dev**.
- **Desktop Windows + macOS auto-update is in scope** (Sparkle/WinSparkle).
- Update URLs are **app-name-neutral** under `https://segno.aquiles.dev/updates/...`
  (no `/segno`; survives the later rename to "segno").
- All updates are **signed**; clients refuse unsigned/mismatched artifacts.

## Scope notes
- **Linux desktop** auto-update is OUT of scope for now (no single standard; the Linux
  target is the appliance via RAUC). Revisit later via AppImage+AppImageUpdate if wanted.
- Rename app → "segno": handled separately by the user later; this plan keeps paths and
  artifact names neutral so it doesn't collide.

## Signing / notarization — the real cross-cutting prerequisite
Auto-update only works if the OS trusts the artifact. This is infra, not code, and gates
the desktop phases especially:
- **macOS:** the app must be **code-signed with an Apple Developer ID + notarized**
  (Gatekeeper blocks auto-installed unsigned apps), and Sparkle updates are signed with an
  **EdDSA** key. Needs a paid Apple Developer account.
- **Windows:** **Authenticode** code-signing cert (avoids SmartScreen warnings on the
  downloaded installer). WinSparkle verifies a DSA/Ed signature on the appcast items.
- **Appliance:** RAUC bundles signed with a self-signed **X.509** CA; public cert baked
  into the rootfs keyring; private key stays in CI secrets, never on device.
→ Confirm which signing identities exist / to acquire before Phases 2–3.

## Architecture
- **Appliance partitions (wic):** `boot` (FAT: firmware + tryboot autoboot config + both
  slots' kernel/dtb/cmdline) · `rootfs.A` · `rootfs.B` · `data`. RAUC `system.conf` maps
  the two rootfs slots + tryboot backend. `/data` (ext4) is shared by both slots and holds
  all Segno user data.
- **Desktop:** `auto_updater` points at `https://segno.aquiles.dev/updates/{macos,windows}/appcast.xml`;
  it downloads the signed build and installs on quit (macOS: Sparkle swaps the .app;
  Windows: runs the signed installer).
- **Server layout (static HTTPS):**
  `/updates/appliance/manifest.json` + `*.raucb`;
  `/updates/macos/appcast.xml` + `*.dmg`/zip;
  `/updates/windows/appcast.xml` + `*-setup.exe`/msix.

## Phases (each an independently-mergeable PR)

### Phase 0 — Appliance: persistent data partition + one-time migration  ← ship first
- `data` partition in the wic; mount `/data`; repoint `segno-kiosk-launch` HOME/XDG/Documents.
- One-time migration script (`deploy/rpi/migrate-data.sh`): rsync current
  `/root/{Documents,.config,.local}` off before the re-layout flash, restore onto `/data`
  after, with verification. Standalone value: reflash stops destroying data.

### Phase 1 — Appliance: RAUC A/B (tryboot) + USB install
- `meta-rauc` + RPi tryboot backend; `rauc` in image; `system.conf` (2 slots + tryboot);
  A/B wic layout; X.509 keyring baked in; produce a signed `.raucb`.
- USB-stick channel: udev/systemd watches for a stick with `*.raucb` → verify + `rauc install`.
- Validate on device: slot flip + rollback-on-failure.

### Phase 2 — Desktop: Windows + macOS auto-update  (parallelizable with Phase 1)
- Integrate `auto_updater` in the desktop app; point at the appcast URLs; wire the
  check/download/install flow with **deferred, user-confirmed** install (see Phase 4 UX).
- Establish signing: macOS Developer ID + notarization + Sparkle EdDSA key; Windows
  Authenticode. (Gated on the signing prerequisite above.)

### Phase 3 — CI/CD release pipeline + server mirror + OTA client  (decisions locked)
GitHub-driven, channel-based — no manual publishing.
- **Triggers → channels:** push to `experimental` branch → **experimental** channel;
  `v*` tag → **production** channel; `workflow_dispatch` → manual (pick channel).
- **Build:** GitHub-hosted runners. Yocto/appliance build restores an **sstate +
  downloads mirror** (hosted on the user's server or ghcr/S3) so it doesn't build cold
  each run (cold Yocto blows the 6h limit; sstate ~5.7GB exceeds GH Actions cache — a
  mirror via `SSTATE_MIRRORS`/`PREMIRRORS` is the viable path). Self-hosted-on-Fedora
  is the fallback if cached GH builds are still too slow. Desktop macOS/Windows builds
  use their respective GH-hosted OS runners.
- **Sign in CI:** RAUC X.509 (appliance) + Sparkle EdDSA / OS code-sign (desktop),
  keys in GitHub Secrets. Signature is the security boundary, not the transport.
- **Deliver:** CI attaches signed artifacts to a **GitHub Release** (prerelease =
  experimental, full release = production) with a per-channel `manifest.json`.
- **Server mirror:** a small sync job on `segno.aquiles.dev` polls the GitHub Releases
  API and mirrors new artifacts into `www/updates/appliance/<channel>/` (+ desktop
  appcast dirs). The device only ever talks to `segno.aquiles.dev` (no GitHub at
  device runtime); GitHub is the source of truth.
- **OTA client (Pi):** pinned to a channel; systemd timer polls
  `/updates/appliance/<channel>/manifest.json`, downloads + verifies + `rauc install`s
  (deferred activation — Phase 4).

Path layout gains a channel segment: `/updates/appliance/{experimental,production}/…`.

### Phase 4 — Update UX (deferred, session-safe activation, all platforms)
- Shared principle: download + stage in the background; **never interrupt a session** —
  install/activate only on explicit "apply & restart" or next launch/power-cycle.
- Appliance: RAUC install to inactive slot now, set tryboot flag, reboot on user action.
- Desktop: Sparkle/WinSparkle "install on quit"; surface an "update ready" affordance.

## Risks / notes
- First appliance transition needs **one manual re-layout flash** + Phase-0 migration;
  all later updates hands-off. Set expectations.
- macOS auto-update is **hard-blocked without notarization** — treat the Apple Developer
  identity as a prerequisite, not a nice-to-have.
- tryboot rollback is one-shot (boot-attempt=1), acceptable per the locked decision.
- A/B doubles the appliance rootfs footprint on the SD; size the card accordingly.
- Every phase is device/platform-gated (blocked-verify) — validate each on real hardware.
