---
date: 2026-06-13
topic: asio-only-windows-and-ui-consolidation
---

# ASIO-only Windows, UI consolidation, and monitoring fix

## What We're Building

A consolidation pass over Loopy that commits fully to **ASIO on Windows** and
simplifies the app's surface area. Five related workstreams:

1. **Remove the audio-setup wizard.** The first-run `_Wizard`/`_EngineStep`/
   `_InputStep`/`_ReadyStep`/`_RunningPanel` flow goes away; the in-app
   `AudioSettingsSection` (in Big Picture settings) becomes the single
   audio-config surface.
2. **Auto-start everywhere, no manual Start/Stop.** The engine auto-starts on
   launch from the saved/last config (or sensible defaults on first run) and
   auto-reopens whenever a setting that needs it changes. The wizard's explicit
   `start()`/`stop()` disappear.
3. **Remove the deprecated "desktop" view.** `UiMode` collapses to a single Big
   Picture mode; the `LooperView` desktop layout, the mode toggle, and the
   `ui_mode` persistence are deleted.
4. **Fix the monitoring bug.** Unify all input monitoring on the per-input live
   monitor system (the routing graph); delete the legacy global passthrough that
   currently double-monitors / monitors-with-nothing-routed.
5. **Windows = ASIO only.** Drop the WASAPI/ASIO selector and WASAPI device
   pickers on Windows; ASIO is hardwired. Relicense the repo **MIT → GPLv3**,
   **vendor the Steinberg ASIO SDK** into the repo (default-on for Windows), and
   **link to ASIO4ALL** (not bundle it) as the generic-driver fallback.

macOS/Linux keep the miniaudio backend unchanged; only the Windows device path
and the cross-cutting UI/monitoring changes are affected.

## Why This Approach

Loopy's Windows story has converged on ASIO (the only way to reach a pro
interface's full channel count — proven on the user's Focusrite at 18 in /
20 out). Keeping WASAPI selectable, a separate first-run wizard, and a second
"desktop" layout are now redundant surfaces that each duplicate config/monitor
logic and create inconsistencies (the WASAPI-vs-ASIO drift we just fixed is a
symptom). Collapsing to one audio surface, one UI mode, and one monitoring path
removes whole classes of "two systems disagree" bugs.

The monitoring bug is the clearest example: the **"Monitor input" toggle** sets
`config.passthrough`, which at engine start auto-enables input 0's live monitor
(`monitors[0]`) with a default stereo mask (`engine.c:1951`). That overlaps the
per-input monitor routing graph (`MonitorCubit` → `le_engine_set_monitor_input`),
so input 0 is audible even with nothing routed, and can double when input 0 is
also routed explicitly. There is no reason to keep two monitor mechanisms — the
per-input system is strictly richer.

Approaches considered for monitoring: (A) unify on per-input [chosen]; (B) keep a
simple toggle that drives the per-input path; (C) gate passthrough so it can't
double. (A) wins because it deletes a whole subsystem rather than papering over
the overlap.

## Key Decisions

- **Monitoring → unify on per-input.** Remove the global passthrough entirely
  (`engine->passthrough`, the `monitors[0]` auto-enable, `StoredAudioConfig.
  monitorInput`, the "Monitor input" toggle). All monitoring flows through the
  per-input routing graph, which already has per-input enable + wet/dry routes +
  FX. Rationale: single source of truth; eliminates the double/ghost monitoring.
- **License → GPLv3, vendor the full SDK.** Change `LICENSE` MIT → GPLv3 and
  commit the entire Steinberg ASIO SDK (~5.5 MB, 39 files) into the repo with its
  Steinberg license intact; remove the `.gitignore` entries; make
  `LOOPY_ENABLE_ASIO` default-ON for Windows. Rationale: GPLv3 permits
  redistributing the GPLv3-licensed SDK; vendoring makes the Windows build
  reproducible with no user-supplied step. (Full SDK chosen over a trimmed set
  for completeness / future use of its sample + docs.)
- **No ASIO driver → link to ASIO4ALL (do not bundle).** When no ASIO driver is
  detected, the app shows a clear message with a **link to the official ASIO4ALL
  download** (`asio4all.org`) so the user can install a generic ASIO driver in
  one click. Rationale: ASIO4ALL is freeware for end-users but its license
  **restricts bundled/commercial redistribution** (you must contact the developer
  for a redistribution license, and bundled installers are explicitly
  discouraged); it is also closed freeware, so vendoring its binary into a GPLv3
  repo is not clean. Link-to-download gives the same outcome with no licensing or
  packaging risk. *(Adjusts the earlier "bundle ASIO4ALL" intent — same UX, safer
  legally.)*
- **WASAPI → hardwire ASIO on Windows.** Windows always selects ASIO; remove the
  backend selector and WASAPI device pickers from the Windows UI. Keep the
  miniaudio backend **code** (it remains the macOS/Linux backend) — Windows just
  never opens it. Rationale: smallest blast radius that still delivers "ASIO
  only" UX; avoids ripping shared cross-platform code.
- **Remove the wizard; settings is the only surface.** Delete the wizard files
  and the first-run `needsSetup` gate; the app always lands on the looper and
  auto-starts the engine. Port the wizard-only running-panel touches worth
  keeping (the ASIO-fallback / status notes) into `AudioSettingsSection`.
- **Remove the desktop view; default Big Picture.** Collapse `UiMode` to a single
  mode, delete `LooperView` + the mode toggle + the `ui_mode` persistence, and
  hardcode the Big Picture theme/layout. The waveform window stays (it's gated by
  its own `WaveformWindowCubit`, not by mode).
- **First-run / auto-start default.** With no saved config, auto-start on the
  **first enumerated ASIO driver** (Windows) at its driver-reported buffer/rate.
  If several drivers exist, pick the first and let settings change it. If none
  exists (and ASIO4ALL isn't installed), land in settings with the engine stopped
  and show the install-a-driver message. No "Start engine" UI anywhere.
- **Remove `exclusive` mode entirely.** WASAPI exclusive mode was Windows-only
  (the toggle only ever showed on Windows). With Windows now ASIO-only — and ASIO
  having no share-mode concept — `exclusive` is dead code on its only platform.
  Delete it end-to-end: `le_config.exclusive`, `le_snapshot.exclusive_active`,
  the share-mode fallback, `StoredAudioConfig.exclusive`, `platformDefaultExclusive`,
  the toggle, and the fallback note. Rationale: YAGNI — removing a now-unreachable
  feature, not keeping it "just in case."
- **`monitorInput` migration.** No schema migration needed: the saved
  `audio.monitor_input` key is simply ignored after passthrough removal, and the
  per-input monitor routes (already persisted by `MonitorCubit`) reproduce
  monitoring. **One-time courtesy migration:** if a user had `monitorInput=true`
  and **no** per-input routes saved, enable input 0 → main out via the per-input
  system so they don't silently lose the "I was hearing my input" behavior.

## Sequencing (recommended PR split)

Five loosely-coupled PRs; the plan-splitting agent confirms in `/plan`:

1. **Monitoring fix** — unify on per-input, delete passthrough (+ courtesy
   migration). Independent, self-contained bug fix, highest immediate value.
2. **Desktop-view removal** — collapse `UiMode`, delete `LooperView` + toggle.
   Independent UI cleanup.
3. **Wizard removal + auto-start** — delete the wizard, drop the `needsSetup`
   gate, always land on the looper with the engine auto-started.
4. **License + SDK vendoring** — relicense GPLv3, vendor the SDK, make ASIO
   default-ON for Windows. The riskiest change; reviewable on its own.
5. **Windows ASIO-only UI** — remove the backend selector + WASAPI device
   pickers; add the no-driver/ASIO4ALL message; remove `exclusive`. Depends on
   ASIO being always-on (PR 4), so it lands after.

## Open Questions

- **ASIO SDK version to vendor.** Pin the exact Steinberg ASIO SDK version
  committed (currently `asiosdk_2.3.3_2019-06-14`) and include its license file.
- **GPLv3 mechanics.** Whether to add `license: GPL-3.0-or-later` to `pubspec.yaml`
  (it has no `license:` field today) and whether to add SPDX headers to first-
  party sources, or just replace `LICENSE`. Confirm `license_check.yaml` (Dart
  deps only) and the cspell dictionary don't assert MIT anywhere.
