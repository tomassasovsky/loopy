---
title: Windows & Linux Native Support
type: feat
date: 2026-06-11
---

## ✨ Windows & Linux Native Support - Extensive

## Overview

Bring Loopy to Windows and Linux at the highest feature parity each OS physically
allows. The C audio engine (`packages/loopy_engine/src/`) is already portable via
vendored **miniaudio** — there are no macOS `#ifdef`s in the DSP, looping, lock-free
ring, or atomic-state code. The only platform-gated code is the loopback channel-label
exclusion (`le_compute_excluded_input_mask`, a `return 0` stub off macOS).

The work splits into three **strictly layered, independently mergeable** PRs:

1. **Portable foundation** (the bulk of the value, zero licensing risk): create the
   missing Linux app scaffold, get both OSes building and running end-to-end
   (record / loop / play / per-input monitor / FX), verify the portable loopback
   features on real hardware, and add compile-only CI for both platforms.
2. **Windows ASIO opt-in label exclusion** (additive, gated, degradable): read
   per-channel labels via `ASIOGetChannelInfo().name` behind a compile-time flag that
   is **off by default** and consumes a **user-supplied, non-vendored** ASIO SDK.
3. **Linux PipeWire spike** (time-boxed, keep-or-document): attempt an `AUX`-index
   heuristic via PipeWire port enumeration; keep only if it proves reliable on the
   target interface, otherwise document the OS limitation.

The honest finding driving the split: **full per-channel-label parity is not uniformly
achievable.** macOS reads arbitrary per-channel name strings via CoreAudio. Windows can
only approximate via ASIO. Linux exposes **no** arbitrary per-channel labels at all.
We pursue every avenue that physically exists and document the rest as an OS limitation
rather than an open TODO. Graceful degradation to today's `return 0` (exclude-nothing)
behavior is mandatory everywhere.

## Problem Statement

Loopy currently ships macOS-only. The audio engine is portable, but:

- **The Linux app scaffold does not exist.** `loopy/linux/` is absent. The engine
  plugin already declares `linux: { ffiPlugin: true }` and ships
  [linux/CMakeLists.txt](packages/loopy_engine/linux/CMakeLists.txt), but there is no
  app-level GTK runner. `flutter create --platforms=linux .` must generate it, then
  flavors must be wired.
- **Neither Windows nor Linux has been run end-to-end on real hardware.** The Windows
  app scaffold ([windows/](windows)) exists and compiles, but the full pipeline
  (record → loop → play → per-input monitor → per-lane FX) has not been exercised on a
  real interface. Linux has never run.
- **The portable loopback features are unverified off macOS.**
  [`le_classify_capture_device`](packages/loopy_engine/src/engine.c:1683) (device-name
  classification: "monitor of", virtual devices like BlackHole/VB-Cable/VoiceMeeter) and
  the audio-level round-trip latency-measurement harness are portable in principle but
  have only been validated on macOS.
- **Per-channel "loopback"-label exclusion is macOS-only** and currently a `return 0`
  stub off macOS ([engine.c:1925](packages/loopy_engine/src/engine.c:1925)). The user
  has RME / MOTU / Focusrite-class hardware on both Windows and Linux and explicitly
  wants maximum parity, but the underlying OS APIs differ fundamentally:
  - **Windows:** WASAPI / DeviceTopology cannot return per-channel name strings
    (`KSJACK_DESCRIPTION` has no name field). The only path is **ASIO**
    `ASIOGetChannelInfo().name`, which RME / MOTU / Focusrite drivers populate. But
    miniaudio has **no ASIO backend**, and the Steinberg ASIO SDK is
    **GPLv3-or-proprietary** (since Nov 2025) — **incompatible with Loopy's MIT license**
    unless ASIO is opt-in, user-supplied, and non-vendored.
  - **Linux:** No stack (ALSA chmaps, PulseAudio, PipeWire ports, JACK aliases) exposes
    arbitrary per-channel labels — all are positional (FL/FR/AUX0…). The same Focusrite
    that advertises "Loopback" channels on macOS surfaces them as generic `AUX` ports on
    Linux. A PipeWire port-enumeration spike is the single avenue worth a time-box, as a
    brittle interface-specific heuristic — not true label parity.

## Proposed Solution

Ship the **portable end-to-end work first as a standalone deliverable** (PR1), then add
the two native-label tracks (PR2, PR3) as additive, opt-in, cleanly-degrading layers.

**Decisions locked in planning:**

| Decision | Choice |
|----------|--------|
| PR sequencing | 3 PRs as brainstormed (foundation → ASIO → PipeWire spike) |
| Linux packaging | **Deferred** — `flutter run` / local build only; AppImage/Flatpak/.deb out of scope |
| CI coverage | **Compile-only** Windows + Linux build jobs (no audio at runtime) |
| ASIO role | **Label-probe only** — capture stays on miniaudio/WASAPI; ASIO reads `ASIOChannelInfo.name` for the excluded-input mask |

**Invariants that hold across all three PRs:**

- **No change to the FFI boundary's shape.** The ~40-function C ABI and the Dart loader
  ([native_audio_engine.dart:26](packages/loopy_engine/lib/src/native_audio_engine.dart:26),
  already branching `.dll` / `.so` / `process()`) are stable. All native-label work lives
  behind `le_compute_excluded_input_mask` and new platform-specific translation units,
  invisible to Dart.
- **Graceful degradation is mandatory.** When ASIO isn't built/available, or the PipeWire
  spike is inconclusive, the engine returns the current no-op mask. The feature becoming
  unavailable is **correct behavior** — the information genuinely isn't exposed by the OS.

## Technical Approach

### Architecture

The platform-gating already lives in one place. Today
[engine.c:1925](packages/loopy_engine/src/engine.c:1925):

```c
static uint32_t le_compute_excluded_input_mask(const char* uid, int channel_count) {
#if defined(__APPLE__)
  return le_macos_excluded_mask(uid, channel_count);
#else
  (void)uid; (void)channel_count;
  return 0;
#endif
}
```

After all three PRs, this becomes the single dispatch point for every platform's label
strategy, each in its own translation unit, each degrading to `0`:

```c
static uint32_t le_compute_excluded_input_mask(const char* uid, int channel_count) {
#if defined(__APPLE__)
  return le_macos_excluded_mask(uid, channel_count);          // existing
#elif defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)
  return le_win_asio_excluded_mask(uid, channel_count);        // PR2, opt-in
#elif defined(__linux__) && defined(LOOPY_ENABLE_PIPEWIRE_LABELS)
  return le_linux_pipewire_excluded_mask(uid, channel_count);  // PR3, opt-in, if kept
#else
  (void)uid; (void)channel_count;
  return 0;                                                    // graceful no-op
#endif
}
```

`le_label_is_loopback` ([engine.c:1696](packages/loopy_engine/src/engine.c:1696)) is
reused **verbatim** by every backend — it already passes its unit tests
([test_engine_core.c:974+](packages/loopy_engine/src/test/test_engine_core.c)). Only the
*source of the label strings* is platform-specific.

### Build wiring

[src/CMakeLists.txt](packages/loopy_engine/src/CMakeLists.txt) already branches on
`WIN32` (links `ole32 winmm`) and `UNIX AND NOT APPLE` (links `Threads`, `${CMAKE_DL_LIBS}`,
`m`). Both the [linux](packages/loopy_engine/linux/CMakeLists.txt) and
[windows](packages/loopy_engine/windows/CMakeLists.txt) plugin entry points already
`add_subdirectory` the shared `src`. New compile-time options (`LOOPY_ENABLE_ASIO`,
`LOOPY_ENABLE_PIPEWIRE_LABELS`) gate the additive sources and their extra includes/links.

### Implementation Phases

---

#### Phase 1 (PR1): Portable Foundation — Linux scaffold, both OSes end-to-end, CI

**Goal:** Both platforms build and run the full pipeline; portable loopback features
verified on real hardware; compile-only CI guards the portable core.

**Tasks & deliverables:**

1. **Generate the Linux app scaffold.**
   - Run `flutter create --platforms=linux --org <existing-org> .` to generate
     `loopy/linux/` (GTK runner: `linux/CMakeLists.txt`, `linux/runner/`,
     `linux/flutter/`). Verify it does not clobber existing config.
   - **Flavors are entrypoint-only on desktop — do NOT hand-roll per-flavor app-name/bundle-id
     CMake.** Flutter desktop has no real `--flavor` app-identity support: the Windows runner
     hardcodes `set(BINARY_NAME "loopy")` with no flavor branching, and the canonical desktop
     invocation (per README) is `flutter run --flavor development --target lib/main_development.dart`
     — i.e. **`--target` selects the entrypoint** ([lib/main_development.dart](lib/main_development.dart) /
     `main_staging.dart` / `main_production.dart`); `--flavor` on Windows/Linux only namespaces the
     build-output directory. Match what Windows already does (nothing flavor-specific in the runner).
     Confirm all three `--target` entrypoints launch; per-flavor *installed app identity* on Linux is
     **net-new work with no repo precedent** — out of scope unless explicitly requested.
   - **Files:** `linux/CMakeLists.txt`, `linux/runner/my_application.cc`,
     `linux/runner/CMakeLists.txt` (generated; minimal-to-no edits expected).

2. **Build & run Windows end-to-end on real hardware.**
   - `flutter run -d windows --flavor development --target lib/main_development.dart` (and a release build).
   - Exercise the full pipeline on the user's RME/MOTU/Focusrite Windows interface:
     record → loop → play → per-input monitor → per-lane FX.
   - Confirm the FFI loader resolves `loopy_engine.dll`
     ([native_audio_engine.dart:30](packages/loopy_engine/lib/src/native_audio_engine.dart:30)).
   - **De-risk `multi_window` early** (see risk table): confirm the `desktop_multi_window`
     waveform sub-window ([run_loopy.dart](lib/app/run_loopy.dart)) works on Windows. Its
     GTK/Linux support is historically the weakest of the three desktop targets — check this
     in the *first* scaffold build, not at PR-close, so a gap doesn't silently block PR1.

3. **Build & run Linux end-to-end on real hardware.**
   - `flutter run -d linux --flavor development --target lib/main_development.dart` (and a release build).
   - Same full-pipeline exercise on the user's Linux interface, including the `multi_window`
     check from task 2 on GTK.
   - Confirm the FFI loader resolves `libloopy_engine.so`
     ([native_audio_engine.dart:31](packages/loopy_engine/lib/src/native_audio_engine.dart:31)).
   - Confirm miniaudio selects a working backend (PipeWire vs ALSA vs Pulse) and capture
     produces non-silent audio. *(Open question: confirm the Linux test box runs PipeWire,
     needed for PR3 applicability.)*

4. **Verify portable loopback features on both OSes.**
   - **Device-name classification** ([`le_classify_capture_device`](packages/loopy_engine/src/engine.c:1683)):
     plug in / enable a virtual device (VB-Cable / VoiceMeeter on Windows; a PipeWire/Pulse
     "Monitor of …" source on Linux) and confirm it classifies as
     `LE_LOOPBACK_VIRTUAL` / detects the "monitor of" prefix. Existing unit tests
     ([test_engine_core.c:911+](packages/loopy_engine/src/test/test_engine_core.c)) already
     cover the string logic — this verifies the *device names the OS actually reports*.
   - **Latency-measurement harness (best-effort, not a hard merge gate):** run the audio-level
     round-trip latency measurement on each OS and confirm a plausible figure. ⚠️ Per repo
     gotcha, loopback measurement + input monitoring can form a feedback loop — confirm
     `measureLatency` disables monitoring on these platforms too. If the figure is implausible
     but the rest of the pipeline works, record it in `docs/PROGRESS.md` as a follow-up rather
     than blocking PR1.

5. **Add compile-only CI jobs.**
   - **Prerequisite — fix the workflow trigger.** [.github/workflows/main.yaml](.github/workflows/main.yaml)
     and `license_check.yaml` trigger only on `branches: [main]`, but this repo's default branch
     is **`master`** — so the workflows currently never run on PRs. Fix the trigger to `master`
     (or confirm the intended default) and verify the jobs actually fire on a PR *before* claiming
     the CI gate is green.
   - Add `windows-latest` and `ubuntu-latest` jobs to `main.yaml` that
     `flutter build windows` / `flutter build linux` (debug) so the portable engine + app can't
     silently regress. **No audio at runtime** (CI has no devices).
   - **Pin the same Flutter `3.41.x`** the existing job uses (these hand-rolled OS build jobs do
     not inherit the VGV reusable workflow's version, so the matrix can drift otherwise).
   - On Linux, install the full GTK build dep set:
     `ninja-build libgtk-3-dev libglib2.0-dev libpango1.0-dev clang cmake pkg-config`
     (don't leave it as "etc." — a missing package is a confusing first-run apt failure).
   - Keep the existing VGV `flutter_package` job for `flutter test`.
   - ⚠️ The local `flutter test` hook is broken — use the absolute Flutter path per repo
     gotchas when running tests locally; CI uses the VGV workflow which is unaffected.

**Success criteria (PR1):**
- [ ] `loopy/linux/` exists and `flutter run -d linux --flavor development --target lib/main_development.dart`
      launches the app. (All three `--target` entrypoints wired; merge gated on `development` running.)
- [ ] Full pipeline (record/loop/play/monitor/FX) verified by hand on real hardware on
      **both** Windows and Linux.
- [ ] `multi_window` waveform sub-window confirmed working (or its fallback documented) on both OSes.
- [ ] Device-name classification produces correct results on both OSes (latency figure best-effort).
- [ ] CI **actually runs on PRs** (trigger fixed) and compiles the Windows + Linux app + engine.
- [ ] README lists Windows + Linux as supported platforms.
- [ ] `le_compute_excluded_input_mask` still returns `0` off macOS (no behavior change yet).

**Estimated effort:** Largest PR. ~Most of the total value. Bulk is hands-on hardware
verification + scaffold generation, not novel code.

---

#### Phase 2 (PR2): Windows ASIO Opt-In Label Exclusion

**Goal:** On Windows, with an opt-in build, read per-channel labels via ASIO and build the
same excluded-input bitmask macOS produces — degrading cleanly to `return 0` when ASIO
isn't built or available.

**Tasks & deliverables:**

0. **De-risking spike — DO THIS FIRST; gates all of PR2 (~30 min, zero committed code).**
   - Validate that `ASIOChannelInfo.name` actually carries a "Loopback"-style string (one that
     [`le_label_is_loopback`](packages/loopy_engine/src/engine.c:1696) matches) on the **user's
     specific Windows interface** (~80% confidence per brainstorm).
   - In the same spike, determine the **ASIO↔WASAPI device-matching heuristic** (task 2's open
     question): does the interface present a name that reliably maps the miniaudio/WASAPI `uid`
     to the right ASIO driver?
   - **Decision tree (close the open question here, don't carry it forward):**
     - Label string present **and** a reliable match exists → proceed with tasks 1–4.
     - Label string absent, **or** no reliable device match → **PR2 is documentation only**
       ("Windows per-channel labels: ASIO probe inconclusive on tested hardware"); ship no code.
   - **Success criterion:** a yes/no on both questions, recorded in the PR description.

1. **CMake opt-in plumbing.**
   - Add `option(LOOPY_ENABLE_ASIO "Build Windows ASIO channel-label probe" OFF)` and a
     `LOOPY_ASIO_SDK_DIR` cache var pointing at a **user-supplied** ASIO SDK (never
     vendored — MIT/GPLv3 conflict). When `ON`, add the ASIO host sources +
     `target_include_directories` for the SDK and `target_compile_definitions(... LOOPY_ENABLE_ASIO)`.
   - **`.gitignore` the SDK location** so a user-supplied GPLv3 SDK can never be accidentally
     committed. Note: the existing `license_check.yaml` gate scans **Dart deps only** — it does
     **not** catch a C SDK in the build tree, so the MIT boundary here is enforced by the
     OFF-by-default flag + `.gitignore` + review, not by CI.
   - **Files:** [src/CMakeLists.txt](packages/loopy_engine/src/CMakeLists.txt), `.gitignore`.

2. **ASIO label-probe translation unit** (`src/win_asio_labels.cpp` or `.c`).
   - **Label probe ONLY** — capture/playback stay on miniaudio/WASAPI. The probe:
     loads the ASIO driver for the target device, calls `ASIOGetChannelInfo()` per input
     channel, runs each `ASIOChannelInfo.name` through the existing
     [`le_label_is_loopback`](packages/loopy_engine/src/engine.c:1696), and sets the bit.
   - Map the miniaudio/WASAPI `uid` to the ASIO driver using the heuristic confirmed in task 0.
     miniaudio's WASAPI IDs are endpoint strings while ASIO enumerates drivers by registry
     name, so the match can be fuzzy on multi-interface rigs. **Rule: prefer no-match over
     wrong-match** — on any ambiguity, return `0` (exclude nothing) rather than risk excluding
     the *wrong* channels (a false-positive mask is worse than a no-op).
   - Expose `uint32_t le_win_asio_excluded_mask(const char* uid, int channel_count)`.
   - **Files:** new `packages/loopy_engine/src/win_asio_labels.c`, declaration in
     [engine_internal.h](packages/loopy_engine/src/engine_internal.h).

3. **Wire the dispatch** in `le_compute_excluded_input_mask`
   ([engine.c:1925](packages/loopy_engine/src/engine.c:1925)) under
   `#elif defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)`.

4. **Tests & docs.** Unit-test the bit-setting logic with a fake channel-name provider
   (the OS-facing ASIO calls aren't unit-testable in CI). Document the opt-in build:
   how to supply the SDK, the flag, and the licensing rationale.

**Success criteria (PR2):**
- [ ] Default build (flag OFF) is byte-for-byte unchanged: `le_compute_excluded_input_mask`
      returns `0` on Windows, no ASIO SDK required, CI still green.
- [ ] With `LOOPY_ENABLE_ASIO=ON` + a local SDK, loopback channels on the user's interface
      are excluded via the same mask path as macOS.
- [ ] No GPLv3 code vendored into the MIT repo.

**Estimated effort:** Medium, **gated on the 30-min spike**. If the spike fails, PR2 reduces
to documentation.

---

#### Phase 3 (PR3): Linux PipeWire Label Spike (time-boxed, keep-or-document)

**Goal:** Determine whether a PipeWire port-enumeration heuristic can flag the loopback
`AUX` pair on the user's Linux interface reliably enough to keep. If yes, ship it behind an
opt-in flag. If no, document the OS limitation and remove the spike code.

**Hard time-box & success criteria (define up front, so it can be cut cleanly):**
*Keep only if* it reliably flags the loopback `AUX` pair on the target interface with **no
false positives** across a few replugs/restarts. Anything flakier is documented as a dead
end, not shipped.

**Prerequisite:** confirm the Linux test box runs **PipeWire** (not bare ALSA) and exposes
the node — established in PR1 Phase 1 task 3.

**Tasks & deliverables:**

1. **Spike:** enumerate capture-node ports via `libpipewire`, reading `PW_KEY_PORT_NAME`
   and `PW_KEY_AUDIO_CHANNEL`. Inspect what the user's interface reports for its loopback
   channels (expected: generic `AUX<n>`). Determine if an `AUX`-index heuristic isolates the
   loopback pair with no false positives.
2. **If reliable:** wrap it in `le_linux_pipewire_excluded_mask` behind
   `option(LOOPY_ENABLE_PIPEWIRE_LABELS OFF)`, link `libpipewire-0.3`, wire the dispatch
   `#elif defined(__linux__) && defined(LOOPY_ENABLE_PIPEWIRE_LABELS)`. Document it as a
   brittle, interface-specific heuristic.
3. **If unreliable:** remove the spike **completely** — the `.c` translation unit, the
   `option(LOOPY_ENABLE_PIPEWIRE_LABELS ...)`, the `libpipewire-0.3` link, the dispatch
   `#elif`, and any header declarations (no half-removed dead config left behind). Document
   Linux per-channel labels as an OS limitation in `docs/` and the engine header comment.
   Device-name classification (which *does* work) remains the Linux loopback path.

**Success criteria (PR3):**
- [ ] A clear keep/cut decision backed by observed port data on real hardware.
- [ ] If kept: opt-in, degrades to `0`, documented as brittle.
- [ ] If cut: limitation documented; default behavior unchanged.

**Estimated effort:** Spike-first, capped. Outcome may be pure documentation.

## Alternative Approaches Considered

1. **Run-first, stub the label exclusion entirely** — ship the portable core, document
   per-channel labels as macOS-only, never attempt ASIO/PipeWire. *Rejected as the sole
   target* because the user has RME/MOTU/Focusrite-class hardware on both OSes and
   explicitly wants maximum parity. (It survives as PR1 + the degradation fallback.)
2. **Vendor the ASIO SDK** — rejected: GPLv3-or-proprietary since Nov 2025, incompatible
   with Loopy's MIT license. Opt-in, user-supplied, non-vendored is the only MIT-safe path.
3. **Route Windows capture through ASIO** (full second backend) — rejected in favor of
   **label-probe only**: capture stays on miniaudio/WASAPI; ASIO is used solely to read
   channel names. Avoids maintaining a second audio backend.
4. **Force per-channel label parity on Linux** — physically impossible; no Linux stack
   exposes arbitrary per-channel labels. The PipeWire `AUX`-heuristic spike is the only
   partial avenue, explicitly brittle and keep-or-cut.

## Acceptance Criteria

### Functional Requirements

- [ ] **PR1:** Loopy builds and runs end-to-end (record/loop/play/per-input monitor/per-lane
      FX) on Windows and Linux on the user's real interfaces.
- [ ] **PR1:** `loopy/linux/` GTK scaffold exists with flavors wired
      (`development`/`staging`/`production`).
- [ ] **PR1:** Portable loopback features verified on both OSes: device-name classification
      (`le_classify_capture_device`) and the latency-measurement harness.
- [ ] **PR1:** `multi_window` output-waveform sub-window works on both OSes.
- [ ] **PR2:** With the opt-in ASIO build + a local SDK, Windows loopback channels are
      excluded via the same mask path as macOS; default build is unchanged.
- [ ] **PR3:** A grounded keep/cut decision for the PipeWire heuristic; if cut, the OS
      limitation is documented.

### Non-Functional Requirements

- [ ] **Performance:** no regression in the audio callback / lock-free ring; the portable
      core is unchanged, only build targets and a platform-gated label probe are added.
- [ ] **Licensing:** no GPLv3 (ASIO SDK) code vendored into the MIT repo at any point.
- [ ] **Degradation:** every native-label path returns `0` (exclude-nothing) when its OS API
      is unavailable; the engine never errors because a label couldn't be read.
- [ ] **FFI stability:** the ~40-function C ABI and the Dart loader are unchanged.

### Quality Gates

- [ ] New label-probe logic unit-tested with a fake name provider (`le_label_is_loopback`
      reuse verified).
- [ ] Compile-only CI green for Windows + Linux on every PR.
- [ ] Each PR independently mergeable and reviewed.
- [ ] Build/opt-in/limitation docs updated (see Documentation Plan).

## Success Metrics

- Both desktop platforms launch and complete a full record→loop→play→monitor→FX cycle on the
  user's hardware (binary: works / doesn't).
- Default-build behavior on Windows/Linux is byte-identical before and after PR2/PR3 (the
  `return 0` mask is preserved unless an opt-in flag is set).
- CI catches a deliberately-introduced portable-core compile break on Windows and Linux.
- ASIO spike confidence resolved from ~80% to a yes/no on the user's interface within the
  30-min time-box before PR2 commits.

## Dependencies & Prerequisites

- **Hardware:** the user's RME/MOTU/Focusrite-class interfaces on a Windows box and a Linux
  box for hands-on verification.
- **Linux:** confirm the test box runs **PipeWire** (gates PR3); GTK build deps
  (`libgtk-3-dev`, `ninja-build`, `clang`, `pkg-config`) for builds + CI.
- **Windows (PR2 only):** a user-supplied Steinberg ASIO SDK locally; a driver that
  populates `ASIOChannelInfo.name`.
- **Toolchain:** Flutter `3.41.x` (per CI), absolute Flutter path locally (test hook gotcha).
- **Upstream done:** portable C core (miniaudio), the FFI loader's `.dll`/`.so` branches, and
  the Windows app scaffold already exist.

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `flutter create --platforms=linux` clobbers existing project config | Low | Med | Run on a clean branch; diff every generated file; only keep `linux/`. |
| Linux flavor wiring on GTK runner differs from macOS/Windows | Med | Med | Resolve early in PR1 task 1; mirror the existing runner that's closest. |
| miniaudio picks a broken/silent backend on the Linux box | Med | High | Verify non-silent capture in PR1 task 3; try forcing PipeWire vs ALSA. |
| `desktop_multi_window` waveform sub-window broken on GTK/Linux (weakest of 3 targets) | Med | Med-High | De-risk in the **first** PR1 scaffold build, not at PR-close; fallback = single-window/in-app visualizer on Linux so it doesn't block PR1. |
| CI workflow trigger is `main` but default branch is `master` → jobs never run on PRs | High (pre-existing) | High | Fix trigger as a PR1 prerequisite; verify jobs fire on a real PR before claiming the gate. |
| Loopback latency measurement feedback-loops + resets the interface | Med | High | Confirm `measureLatency` disables input monitoring on Win/Linux (known macOS gotcha). |
| `ASIOChannelInfo.name` lacks "Loopback" on user's interface | ~20% | High (kills PR2) | **30-min spike first**; if it fails, PR2 → documentation only. |
| ASIO↔WASAPI device matching by `uid`/name is ambiguous | Med | Med | Document matching heuristic + failure mode; degrade to `0` on no match. |
| PipeWire `AUX` heuristic is flaky / false-positives | High | Low | Hard time-box + no-false-positive keep criterion; cut to docs if it fails. |
| Test box runs bare ALSA, not PipeWire | Med | Low | Confirm in PR1; if ALSA-only, PR3 is N/A and documented as such. |
| Vendoring GPLv3 ASIO SDK into MIT repo | Low | Critical | Opt-in flag OFF by default, SDK never committed; CI builds without it. |

## Resource Requirements

- Single engineer with the two test machines (Windows + Linux) and the audio interfaces.
- No new infra beyond two CI runners (`windows-latest`, `ubuntu-latest`).
- PR2 additionally needs a locally-downloaded ASIO SDK (not in repo, not in CI).

## Future Considerations

- **Linux packaging (deferred):** AppImage / Flatpak / `.deb` once the GTK runner is stable.
- **Windows packaging / signing:** MSIX or installer — out of scope here.
- **Headless smoke CI:** booting the engine against a null/dummy device to catch link/init
  regressions, if compile-only proves insufficient.
- **iOS/Android:** the FFI plugin already declares some mobile hooks; not in scope.

## Documentation Plan

- `docs/PROGRESS.md` — update platform status (Windows/Linux running; per-channel labels:
  macOS full, Windows opt-in ASIO, Linux device-name only / OS limitation).
- Engine header comment near
  [`le_compute_excluded_input_mask`](packages/loopy_engine/src/engine.c:1925) — document the
  per-platform label strategy and the deliberate `return 0` degradation.
- A build doc for the **opt-in ASIO** path (PR2): flag, SDK supply, licensing rationale.
- Linux per-channel-label **OS limitation** note (PR3 outcome, if cut).
- README — add Windows/Linux to supported platforms once PR1 ships.

## References & Research

### Internal References

- Platform dispatch / stub: [engine.c:1925](packages/loopy_engine/src/engine.c:1925)
- macOS label reader (the parity target): [engine.c:1860-1920](packages/loopy_engine/src/engine.c:1860)
- Reusable label matcher: [engine.c:1696](packages/loopy_engine/src/engine.c:1696)
- Device-name classifier: [engine.c:1683](packages/loopy_engine/src/engine.c:1683)
- Label/classifier unit tests: [test_engine_core.c:911](packages/loopy_engine/src/test/test_engine_core.c)
- FFI loader (`.dll`/`.so`/`process()`): [native_audio_engine.dart:26](packages/loopy_engine/lib/src/native_audio_engine.dart:26)
- Shared build (WIN32 / UNIX links): [src/CMakeLists.txt](packages/loopy_engine/src/CMakeLists.txt)
- Linux plugin entry: [linux/CMakeLists.txt](packages/loopy_engine/linux/CMakeLists.txt)
- Windows plugin entry: [windows/CMakeLists.txt](packages/loopy_engine/windows/CMakeLists.txt)
- Flavor entrypoints: [lib/main_development.dart](lib/main_development.dart) (+ staging/production)
- Shared run + multi_window: [lib/app/run_loopy.dart](lib/app/run_loopy.dart)
- CI workflow: [.github/workflows/main.yaml](.github/workflows/main.yaml)
- Brainstorm: [docs/brainstorm/2026-06-11-windows-linux-native-brainstorm-doc.md](docs/brainstorm/2026-06-11-windows-linux-native-brainstorm-doc.md)

### External References

- miniaudio (vendored): WASAPI (Windows) / ALSA/PulseAudio/JACK (Linux) backends.
- Steinberg ASIO SDK — GPLv3-or-proprietary since Nov 2025 (licensing constraint).
- PipeWire `pw-cli` / `libpipewire-0.3` — `PW_KEY_PORT_NAME`, `PW_KEY_AUDIO_CHANNEL`.
- Flutter desktop: `flutter create --platforms=linux`, GTK runner flavors.

### Related Work

- Repo gotchas: broken `flutter test` hook (use absolute Flutter path); FFI plugin
  hand-authored; macOS mic-entitlement + loopback feedback-loop note.
- Prior platform/FFI plans: [2026-06-08-feat-flutter-desktop-loopstation-plan.md](docs/plan/2026-06-08-feat-flutter-desktop-loopstation-plan.md),
  [2026-06-09-feat-audio-device-selection-part-a1-native-ffi-plan.md](docs/plan/2026-06-09-feat-audio-device-selection-part-a1-native-ffi-plan.md)
