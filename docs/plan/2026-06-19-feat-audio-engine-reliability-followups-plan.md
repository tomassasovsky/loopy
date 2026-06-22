---
title: "feat: audio-engine reliability follow-ups (xrun, CI, ASIO recovery, loopback labels)"
type: feat
date: 2026-06-19
---

## Audio-engine reliability follow-ups - Extensive

## Overview

The structural robustness program (engine.c split, RT-callback decomposition, FX
vtable, typed command ring, segmented Dart interface — see
[2026-06-19-refactor-audio-engine-robustness-plan.md](2026-06-19-refactor-audio-engine-robustness-plan.md))
is complete. This plan captures the **functional** gaps that surfaced while doing
it: places the engine is explicitly incomplete (`reserved` / "deferred" / "future
work" / stub), ranked by how much they affect a *robust* engine rather than how
visible they are.

Each item is an independent PR; they share no ordering except where noted. The
acceptance bar matches the engine's existing discipline: the native suites
(`src/test/run_native_tests.sh`) stay green, `le_engine_process` golden output is
unchanged where behaviour is meant to be unchanged, every TU is clean under
`-Wall -Wextra`, and the Dart analyze + test suites stay green.

| PR | Item | Category | Value |
|----|------|----------|-------|
| **P1** | XRun / dropout detection | reliability | **high** |
| **P2** | Native + macOS builds in CI | process | **high** |
| **P3** | ASIO device recovery (sample-rate / reset / hot-swap) | reliability | high |
| **P4** | Windows/Linux loopback-channel exclusion | correctness | medium |
| **P5** | Finish the FX vtable (per-type prepare / reset) | extensibility | medium |
| **P6** | Smaller deferred items (grab-bag) | mixed | low |

## P1 — XRun / dropout detection

**Problem.** `le_snapshot.xrun_count` is hardcoded to `0` and marked "reserved;
xrun detection lands later" ([loopy_engine_api.h:335](../../packages/loopy_engine/src/core/loopy_engine_api.h),
[engine_snapshot.dart:412](../../packages/loopy_engine/lib/src/engine_snapshot.dart)).
The engine cannot currently report buffer under/overruns — the one signal that
tells a performer (or a bug report) that audio actually glitched. For an engine
whose whole contract is "the RT callback never stalls," not surfacing when the
*device* starved is the biggest reliability blind spot.

**Approach.**
- miniaudio path: there is no portable per-callback xrun flag, so detect
  starvation indirectly — track wall-clock vs. expected frame cadence, or use the
  backend-specific signal where miniaudio exposes one (WASAPI/CoreAudio/ALSA
  underrun counters via `ma_device` internals). Increment an `_Atomic uint32_t`
  `a_xruns` from the RT-adjacent path (store-only, no work on the audio thread).
- ASIO path: the SDK reports `kAsioBufferSizeChange` / overload via the message
  callback — wire the overload notification into the same counter.
- Publish into `le_snapshot.xrun_count` (already present); surface in
  `EngineSnapshot.xrunCount` (already present, just stops being always-0). The
  Dart/UI can then show a dropout indicator.

**Files.** `core/engine_process.c` (or the device-notification seam),
`core/engine_miniaudio.c`, `asio/win_asio_device.cpp`, `engine_private.h`
(`a_xruns` already exists), snapshot publish in `core/engine_snapshot.c`.

**Acceptance.** A deterministic test that forces a starvation condition (or
injects the counter via a test seam) sees `xrun_count` increment; golden output
of the normal path unchanged (no xruns in the synthetic tests).

**Risk.** Low-medium — the counter is store-only on the RT side; the detection
heuristic is the subtle part. Keep it conservative (never false-positive in the
deterministic tests).

## P2 — Native + macOS builds in CI

**Problem.** CI builds Windows + Linux desktop *compile-only* and never runs the
native C test suites (the golden gate) or builds macOS/iOS. That is exactly why
the S1 split silently broke the macOS CocoaPods forwarders — nothing compiled
them. The strongest correctness gate in the project (`run_native_tests.sh`,
bit-identical golden) is manual-only.

**Approach.**
- Add a CI job that runs `bash packages/loopy_engine/src/test/run_native_tests.sh`
  on Linux (cheapest; the suite is device-free) — gates every engine change on
  "ALL PASSED".
- Add a macOS job that at least *compiles* the plugin (`flutter build macos
  --debug`) so the CocoaPods forwarders can't silently rot again; iOS optional.
- Optionally archive the golden output as a CI artifact for diffing.

**Files.** `.github/workflows/main.yaml`.

**Acceptance.** CI runs the native suites green; a deliberately-broken forwarder
fails the macOS job.

**Risk.** Low (CI-only). macOS runners are slower/costlier — scope to debug build.

## P3 — ASIO device recovery

**Problem.** The ASIO callback no-ops sample-rate change, reset, and hot-swap
("Out of Scope", [win_asio_device.cpp:206,224](../../packages/loopy_engine/src/asio/win_asio_device.cpp)).
If another app reconfigures the shared ASIO driver (sample rate, buffer size) or
the device resets, the engine declines rather than recovering — on Windows, the
primary target, that is a real "audio just stopped" failure mode.

**Approach.** Handle the ASIO `asioMessage` reset/resync requests: on
`kAsioResetRequest` / `kAsioResyncRequest`, tear down and re-open through the same
`le_device_backend` seam the lifecycle already uses, republishing
`a_device_present` / negotiated rate so the Dart reconnect layer (already present
in `looper_repository`) drives recovery. Mirror the existing device-lost →
`device_present = 0` → restart path.

**Files.** `asio/win_asio_device.cpp`, possibly `core/engine.c` lifecycle, the
device-present publication.

**Acceptance.** Manual on Windows + ASIO hardware (not unit-testable without a
driver); the pure ASIO bridge math (`engine_convert.c`) stays covered by its
existing tests. Document the manual test steps.

**Risk.** Medium — touches live-device teardown/re-open; Windows-only, hard to
unit-test. Gate behind the existing reconnect machinery to reuse tested paths.

## P4 — Windows/Linux loopback-channel exclusion

**Problem.** Loopback-input exclusion (so an interface's "Loopback"/"Loop 1/2"
channels are never recorded/metered/monitored — they carry our own output) only
works on macOS via Core Audio labels. Windows (ASIO) and Linux return an empty
mask ([engine_platform.h:42](../../packages/loopy_engine/src/core/engine_platform.h),
[engine_linux.c:260](../../packages/loopy_engine/src/platform/engine_linux.c)).
On those platforms a loopback channel inflates meters and can be recorded.

**Approach.** The pure core already exists and is tested:
`le_excluded_mask_from_names(get_name, ctx, n)` (`engine_devices.c`). Only the
*name source* is per-OS. Windows/ASIO: the driver exposes per-channel names
(`ASIOGetChannelInfo`) — `win_asio_labels.cpp` already probes channel info, so
feed those names through the existing pure mask builder. Linux/PipeWire: read
port labels where available; otherwise leave 0 (documented).

**Files.** `platform/engine_windows.c` (+ `asio/win_asio_labels.cpp` channel
names), `platform/engine_linux.c`, reusing `engine_devices.c`'s pure core.

**Acceptance.** The pure mask builder is already unit-tested with a fake provider;
add a Windows case feeding ASIO-style names. Manual verify on a Scarlett-class
interface.

**Risk.** Low-medium — the risky math is already pure + tested; only the
name-source plumbing is new.

## P5 — Finish the FX vtable (per-type prepare / reset)

**Problem.** S3 put `process` + `latency` behind the effect vtable, but per-type
allocation still lives centrally in `le_fx_prepare_entry` (the
`needs_ring`/`needs_right`/`needs_pv` flags) and reset is the generic
`le_fx_entry_reset`. So adding an effect still edits a central allocator —
"one effect = one file" is ~80% there, not 100%.

**Approach.** Add `prepare(fx, slot, sr, cap)` (lazy alloc, returns OK/OOM) and
optionally `reset(fx, slot, chan)` to `le_fx_vtable`; move each type's allocation
needs into its own `prepare`. Keep the OOM free-order discipline
(`le_fx_prepare_entry`'s `owned[]` rollback) — likely by having `prepare` report
what it allocated. This unblocks a hosted VST3/CLAP plugin as purely a new row.

**Files.** `core/engine_fx.c` / `engine_fx.h`, `core/engine_commands.c`
(`le_fx_prepare_entry` becomes a thin dispatch).

**Acceptance.** All FX tests + golden bit-identical; OOM-rollback test still
passes (add one if absent).

**Risk.** Medium — the OOM free-order logic is intricate; preserve it exactly.

## P6 — Smaller deferred items (grab-bag)

Low-value individually; batch as convenient.

- **Stream-to-disk for long loops** — loops are RAM-capped (~30 s default,
  [engine.c:172](../../packages/loopy_engine/src/core/engine.c)). Real long-form
  looping needs disk streaming. Largish; only if a user wants > a few minutes.
- **Backend built-in loopback auto-routing** for the latency harness
  ([loopy_engine_api.h:75](../../packages/loopy_engine/src/core/loopy_engine_api.h)).
- **MIDI input timestamp quantization** — `ts_us` is captured but unused
  ([loopy_engine_api.h:749](../../packages/loopy_engine/src/core/loopy_engine_api.h));
  could quantize pedal hits to the loop grid.
- **Dedicated lower-latency PSOLA buffer** — PSOLA currently reuses the PV
  accumulator at PV latency ([engine_fx.c:349](../../packages/loopy_engine/src/core/engine_fx.c)).
- **Per-step RT unit tests** — expose the S2 steps (`mix_tracks_frame`, …) via the
  `engine_internal.h` seam for isolated tests (overdub-feedback math, seam
  crossfade) beyond the current black-box golden coverage.
- **Stale doc fix** — `le_config.backend` says "Accepted and ignored until the
  ASIO backend lands" ([loopy_engine_api.h:246](../../packages/loopy_engine/src/core/loopy_engine_api.h));
  it *is* honored (`engine.c:406` → `le_select_backend(config->backend)`). One-line.

## Recommended order

**P1 (xrun)** and **P2 (CI)** first — together they make the engine *observably*
robust and keep it that way. Then **P3/P4** for platform resilience/correctness on
the Windows-primary target. **P5** when effects work is next on the roadmap. **P6**
opportunistically (the stale-doc fix is a free win any time).
