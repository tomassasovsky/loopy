---
title: ASIO Backend Part 2 — ASIO Device Backend + Backend-Selector UI
type: feat
date: 2026-06-12
brainstorm: docs/brainstorm/2026-06-12-asio-audio-backend-windows-brainstorm-doc.md
part: 2 of 2
---

## 🎚️ ASIO Backend Part 2 — Full Multichannel I/O on Windows

> **Part 2 of 2.** This PR adds the real ASIO capture/playback backend behind the
> seam from Part 1, plus the Dart/repository/UI stack that selects it, persists
> it, and surfaces the negotiated reality. ASIO stays opt-in behind
> `LOOPY_ENABLE_ASIO` with a user-supplied GPLv3 SDK; the default build and
> macOS/Linux are byte-for-byte unaffected.

## Dependencies

- **Part 1** ([…-part-1-plan.md](docs/plan/2026-06-12-feat-asio-audio-backend-windows-part-1-plan.md))
  — the `le_device_backend` seam, the dispatcher in `le_engine_start`,
  `le_select_backend`, and the FFI struct fields (`le_config.backend`/`asio_driver`,
  `le_device_info` channel counts, `le_snapshot.active_backend`) plus their Dart
  mirrors. **Must merge first.**

## Overview

Loopy on Windows sees only **2 channels** of a pro multichannel interface because
the Focusrite (18-in / 20-out class) driver publishes only its first analogue
pair to WASAPI. Inputs 3–18 and outputs 3–20 exist **only** inside the device's
**ASIO** driver (diagnosed, not assumed: a probe reported `max ch: shared=2
exclusive=2` for every direction).

This PR adds a **real ASIO duplex backend** (`win_asio_device.cpp`,
`#if LOOPY_ENABLE_ASIO`): load the driver, create its buffers, run its real-time
`bufferSwitch` callback, and feed the **existing, unchanged** `le_engine_process`
at the driver's full channel count. It plugs into Part 1's seam, so the SPSC ring,
the atomic snapshot, and the looper/lane/FX DSP are reused as-is. The Dart engine
layer, repository/persistence, auto-start, and the audio-setup UI gain a
**backend selector** ("WASAPI / ASIO") and, under ASIO, a single **driver picker**
that drives all I/O. When ASIO isn't built, no driver is selected/installed, or
ASIO open fails, the engine **falls back to WASAPI** and the **negotiated backend
is reported through the snapshot** so the UI shows reality, not just intent.

## Decisions Locked (with the user)

| Decision | Choice |
|----------|--------|
| Bridge architecture | **Device-backend seam** (Part 1): miniaudio and ASIO both feed the same `le_engine_process`. |
| ASIO selection UX | **Backend selector + ASIO driver picker**: choosing ASIO swaps the two device pickers for one "ASIO driver" picker. |
| Buffer / sample rate | App maps to ASIO-allowed sizes: snap requested buffer into `ASIOGetBufferSize` range; request rate via `ASIOCanSampleRate`/`ASIOSetSampleRate`. |
| First deliverable | Core end-to-end; polish deferred. |

### Resolved open questions

| OQ | Resolution |
|----|------------|
| **OQ1** — `le_config` backend representation | `int32_t backend` enum + `char asio_driver[256]` (landed in Part 1). |
| **OQ2** — channel counts before open | Per-driver probe fills `le_device_info` so the picker shows "18 in / 20 out" pre-open; the post-open snapshot carries the authoritative negotiated counts. **Guarded against re-entrancy** (see Edge cases R1). |
| **OQ3** — active-backend truth | `le_snapshot.active_backend` (landed in Part 1); a fallen-back ASIO open reports WASAPI. |
| **OQ4** — routing persistence scope | **Not** backend-scoped; index 0 is index 0; switching down to WASAPI leaves lanes on inputs ≥2 / outputs ≥2 recording silence / playing nowhere (documented behavior). |
| **OQ5** — ASIO driver as "pinned device" for the banner | A selected ASIO driver counts as pinned for `_detectConnectivity`. |

## Technical Approach

Build in dependency order: **Native ASIO backend → FFI regen → Dart engine →
Repository/persistence → Auto-start → Presentation.**

### The ASIO bridge

ASIO differs from miniaudio's callback in three ways the bridge absorbs **inside
the ASIO TU**, so the engine core never sees it:

1. **Non-interleaved, per-channel buffers** (`ASIOBufferInfo[]`): de-interleave on
   the way in (gather N input blocks → one interleaved f32 buffer), interleave on
   the way out.
2. **Native sample formats** (`ASIOSTInt32LSB`/`Int24LSB`/`Float32LSB`/…, per
   `ASIOChannelInfo.type`): convert each to/from f32 in the callback.
3. **ASIO's own RT thread + buffer-switch model**: do de-interleave → convert →
   `le_engine_process` → convert → interleave entirely within `bufferSwitch`.
   **Scratch buffers are pre-allocated at open** (sized
   `max_buffer_frames * LE_MAX_CHANNELS`), never in the callback — the engine's RT
   contract (no locks/allocs) is preserved.

Channel mapping is direct: ASIO channel *c* → engine channel *c*.
`LE_MAX_CHANNELS = 32` covers 18/20.

### Layer 1 — The ASIO device backend (`#if LOOPY_ENABLE_ASIO`)

**1a. Pure bridge math** — declared in
[engine_internal.h](packages/loopy_engine/src/engine_internal.h), defined in
engine.c (platform-agnostic, no ASIO headers), so the riskiest unit is tested
off-thread without hardware:

```c
typedef enum { LE_SMP_I16, LE_SMP_I24, LE_SMP_I32, LE_SMP_F32 } le_sample_fmt;
void le_deinterleave_in(float* out_interleaved, const void* native_block,
                        le_sample_fmt fmt, int chan, int channel_count, int frames);
void le_interleave_out(void* native_block, const float* in_interleaved,
                       le_sample_fmt fmt, int chan, int channel_count, int frames);
```
Tests (`test_engine_core.c`): `test_bridge_roundtrip_f32` (interleave∘deinterleave
== identity); `test_bridge_convert_int32/int24/int16` (known native byte patterns
↔ f32, `*LSB` endianness correct); `test_bridge_channel_scatter_gather` (3-channel
block lands at the right interleaved positions).

**1b. Buffer-size pick helper (pure, testable)** — engine.c, unit-tested:

```c
/* Snap a requested buffer size to the nearest ASIO-allowed size given
 * (min,max,preferred,granularity). granularity -1 => powers of two only;
 * 0 => only `preferred`; >0 => linear step. */
int32_t le_asio_pick_buffer(int32_t requested, int32_t min, int32_t max,
                            int32_t preferred, int32_t granularity);
```
Tests: powers-of-two driver, fixed (granularity 0 → always `preferred`), linear
step, and a request outside the set snapping to `preferred`.

> **Scope note:** `le_asio_buffer_choices` (a *set* of selectable chips) is **NOT**
> in this PR — the v1 UI does not derive chips from the driver before open (see
> Presentation §7c) and it would produce data nothing consumes. It is deferred to
> the richer-pre-open-probe follow-up (Out of Scope). Only `le_asio_pick_buffer`
> (used at open to guarantee a valid size) ships here.

**1c. The ASIO backend TU** — new `win_asio_device.cpp`
(`#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)`, mirroring
[win_asio_labels.cpp](packages/loopy_engine/src/win_asio_labels.cpp)). Exposes
`extern "C" const le_device_backend le_asio_backend` (declared in
`win_asio_device.h`):
- **`le_asio_open`**: `loadAsioDriver(cfg->asio_driver)` → `ASIOInit`
  (sysRef = `GetDesktopWindow()`) → `ASIOGetChannels` (clamp to `LE_MAX_CHANNELS`)
  → rate negotiate (`ASIOCanSampleRate(cfg->sample_rate)` ? `ASIOSetSampleRate` :
  keep `ASIOGetSampleRate`) → buffer pick (`ASIOGetBufferSize` +
  `le_asio_pick_buffer`) → read each channel's `ASIOChannelInfo.type` into a
  per-channel `le_sample_fmt` table → `ASIOCreateBuffers` (register the static
  `ASIOCallbacks`) → pre-allocate interleaved scratch → fill
  `le_device_open_result` (`active_backend = LE_BACKEND_ASIO`, `device_name =
  asio_driver`, `exclusive_active = 0`). **On ANY failure: `ASIOExit`, return
  non-OK** so the dispatcher falls back (1e).
- **`bufferSwitch(index, directProcess)`** (static; engine handle held in a
  file-static set at open, like the SDK host pattern): de-interleave each input
  block → `le_engine_process(engine, out_scratch, in_scratch, blockFrames)` →
  interleave each output block → `ASIOOutputReady()` if supported. **No allocs/locks.**
- **`bufferSwitchTimeInfo`** delegates to `bufferSwitch`.
- **`sampleRateDidChange`/`asioMessages`**: minimal for v1 (set `device_present`
  appropriately; reset/hot-swap **deferred** — return defaults). The seam must not
  preclude wiring them later.
- **`le_asio_start`**: `ASIOStart`; `store_i32(&engine->a_device_present, 1)`.
- **`le_asio_stop`/`le_asio_close`** (teardown + lifetime barrier):
  **`ASIOStop` first** — per the ASIO spec it guarantees `bufferSwitch` will not be
  called again after it returns — **then** clear the file-static engine pointer,
  `ASIODisposeBuffers`, `ASIOExit`, free scratch, `a_device_present = 0`. Clearing
  the pointer only after `ASIOStop` returns is a **correctness requirement** (no
  use-after-free / no callback racing teardown), not polish.

**1d. `le_select_backend` returns `&le_asio_backend`** under `#if LOOPY_ENABLE_ASIO`
when `backend == LE_BACKEND_ASIO`. The symbol reference is inside the `#if`, so the
default build still links no ASIO symbol (Part 1's link-time guarantee holds).

**1e. Dispatcher fallback** — in `le_engine_start` (Part 1's dispatcher): if the
selected backend is ASIO and `be->open` returns non-OK, **retry once with the
miniaudio backend**, same `config` (channel fields stay 0 = device default):

```c
if (config->backend == LE_BACKEND_ASIO && r != LE_OK) {
  be = &le_miniaudio_backend;             /* WASAPI fallback */
  r = be->open(engine, config, &info);
}
```
`info.active_backend` then reflects what actually opened. **Inline** — this is two
lines with three total outcomes; no extracted `le_decide_backend_fallback` helper
(the dispatcher's behavior is covered end-to-end by the seam tests, and the ASIO
fallback, unlike the share-mode fallback, resets no config fields).

**1f. ASIO enumeration with channel probe + re-entrancy guard** — `extern "C"`:

```c
LE_EXPORT int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                            int32_t* count);
```
Behind `LOOPY_ENABLE_ASIO`, in `win_asio_device.cpp`: `getDriverNames`, then per
driver `loadAsioDriver`→`ASIOInit`→`ASIOGetChannels`→`ASIOExit` to fill
`name`/`input_channels`/`output_channels` (`id` = driver name; `is_default` = 0;
`isInput` is N/A at the C level — see Dart mapping in 3c). Degrades to 0 / omits a
driver on any probe failure, like the label probe. **Without `LOOPY_ENABLE_ASIO`**,
a stub in engine.c returns `*count = 0, LE_OK`.

> **R1 — ASIO global-state re-entrancy (correctness).** The ASIO host SDK uses a
> **process-global single loaded driver** (`loadAsioDriver`/`ASIOInit`/`ASIOExit`
> operate on global state). A per-driver enumeration probe **must never run while
> an ASIO device is open** — calling `ASIOInit`/`ASIOExit` on the global would tear
> down the live `bufferSwitch`. The label probe is safe today only because it never
> races a live ASIO device; this PR makes ASIO the running backend. **Contract:**
> `le_enumerate_asio_drivers` is a no-op (returns the last-known list / `*count`
> for the open driver from the snapshot, probing nothing) whenever an ASIO engine
> is currently running. The Dart side enforces this: the cubit does **not** call
> `enumerateAsioDrivers()` while `engineStatus.activeBackend == asio` (it
> enumerates only when stopped / on WASAPI). A Dart test asserts this.

**CMake** — add `win_asio_device.cpp` to the `LOOPY_ENABLE_ASIO` `target_sources`
block beside `win_asio_labels.cpp`
([CMakeLists.txt:90](packages/loopy_engine/src/CMakeLists.txt)). **No new SDK
sources** are needed — the duplex backend links the same
`common/asio.cpp`/`host/asiodrivers.cpp`/`host/pc/asiolist.cpp` objects already
listed, and `enable_language(CXX)` (line 87) covers the new TU.

### Layer 2 — FFI bindings (regen)

The structs already grew in Part 1, so the only new binding is the
`le_enumerate_asio_drivers` function symbol. Regenerate + `dart format`
([PROGRESS.md](docs/PROGRESS.md)); verify the diff is just the new function.

### Layer 3 — Dart engine layer

**3a. `AudioEngine.enumerateAsioDrivers()`** —
[audio_engine.dart](packages/loopy_engine/lib/src/audio_engine.dart): add
`List<AudioDevice> enumerateAsioDrivers();` (returns `[]` off-ASIO builds /
non-Windows). Implement in
[native_audio_engine.dart](packages/loopy_engine/lib/src/native_audio_engine.dart)
as a **new marshalling method modeled on** `_enumerate` (not an overload — the
existing `_enumerate` is hardwired to the playback/capture native symbols and
`isInput`). It calls `le_enumerate_asio_drivers`, reuses the `_maxDevices` buffer,
reads the channel fields, and tags each result as a **duplex** device:
`AudioDevice(..., isInput: false, inputChannels: …, outputChannels: …)`.

**3b. Duplex tagging contract** —
[audio_device.dart](packages/loopy_engine/lib/src/audio_device.dart): an ASIO
driver is one duplex device. It sets `isInput = false` and is **never** routed
through `AudioSetupState.playbackDevices`/`captureDevices` (which partition on
`isInput`); ASIO drivers live only in the separate `asioDrivers` list (§7a). No
new `AudioDevice` field is needed — the `inputChannels`/`outputChannels` from
Part 1 carry the counts the picker shows.

**3c. `MockAudioEngine`** —
[mock_audio_engine.dart](packages/loopy_engine/lib/src/mock_audio_engine.dart):
**deterministic rule** — `enumerateAsioDrivers()` returns one fake driver
("Mock ASIO Device", 18 in / 20 out); `start` with `backend == asio` "succeeds"
and the snapshot reports `activeBackend == asio` (echo intent). **The fallback
branch (requested ASIO, reality WASAPI) is therefore NOT exercised by the mock** —
the widget test drives it directly by seeding a state with `backend: asio` +
`engineStatus.activeBackend: wasapi`.

**Tests:** loopy_engine package — `enumerateAsioDrivers` marshalling (against a
statically linked test binary or the mock), duplex tagging.

### Layer 4 — Repository + persistence (Domain)

**4a. `EngineStatus`** —
[engine_status.dart](packages/looper_repository/lib/src/models/engine_status.dart):
add `final AudioBackend activeBackend` (default `wasapi`) to the constructor and
**`props`** (this class **is** Equatable); map it at
[looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart):
`activeBackend: snapshot.activeBackend`.

**4b. `StoredAudioConfig` + keys** —
[settings_repository.dart](packages/settings_repository/lib/src/settings_repository.dart):
add `final AudioBackend backend` (default `wasapi`) + `final String asioDriver`
(default `''`); update hand-written `==`/`hashCode`. New keys
`_audioBackendKey = 'audio.backend'`, `_audioAsioDriverKey = 'audio.asioDriver'`.
- `saveAudioConfig`: persist `config.backend.name` and `config.asioDriver`.
- `loadAudioConfig`: **forward-compatible** read — resolve the stored name with a
  guard so a future enum value written by a newer build doesn't crash an older one
  (`AudioBackend.values.asNameMap()[name] ?? AudioBackend.wasapi`, mirroring the
  defensive `loadUiMode` pattern at
  [settings_repository.dart:120](packages/settings_repository/lib/src/settings_repository.dart));
  `asioDriver ?? ''`).
- Repository stays **platform-agnostic** — no `dart:io`; ASIO availability is a
  presentation-layer decision (§7b), as the exclusive-mode default is.

**Tests:** [settings_repository_test.dart](packages/settings_repository/test/settings_repository_test.dart)
— round-trip of `backend`/`asioDriver`; an unknown stored backend name resolves to
`wasapi` (forward-compat).

### Layer 5 — Auto-start path

[audio_bootstrap.dart](lib/app/audio_bootstrap.dart): thread `backend`/`asioDriver`
into the auto-start `EngineConfig` (this assembly is **duplicated** from the
cubit's `_engineConfig`; both must add the fields or relaunch-into-ASIO diverges):

```dart
final stored = await settings.loadAudioConfig();
... EngineConfig(..., backend: stored.backend, asioDriver: stored.asioDriver)
```

If `backend == asio` but the saved driver is gone (E1), the native dispatcher
falls back to WASAPI; the cubit reads `engineStatus.activeBackend` and surfaces it
(§7d). No UI in bootstrap.

### Layer 7 — State, Cubit, UI (Presentation)

**7a. `AudioSetupState`** —
[audio_setup_state.dart](lib/audio_setup/cubit/audio_setup_state.dart): add
`final AudioBackend backend` (intent; default `wasapi`), `final String asioDriver`
(default `''`), `final List<AudioDevice> asioDrivers` (default `const []`) to the
constructor, `copyWith`, `props`. Derived getters: `bool get isAsio`,
`AudioDevice? get selectedAsioDriver`. **No `bufferChoices`/`sampleRateChoices`
getters** — v1 uses the existing static `bufferSizes`/`sampleRates` lists directly
(the driver's allowed sets aren't probed pre-open; see §7c). Add a
`// TODO: derive from ASIO driver probe (deferred — see Out of Scope)` at the
static-list usage so the limitation is explicit.

**7b. `AudioSetupCubit`** —
[audio_setup_cubit.dart](lib/audio_setup/cubit/audio_setup_cubit.dart):
- **Availability gate** (single source, like `_defaultExclusive`):
  `static bool get _asioSelectable => defaultTargetPlatform ==
  TargetPlatform.windows;`. ASIO is offered only when `_asioSelectable` **and**
  `state.asioDrivers.isNotEmpty` (default build enumerates none → selector hidden;
  G6).
- Load `asioDrivers` (`_repository.asioDrivers()` → `enumerateAsioDrivers`) in the
  constructor hydrate `emit` **only when not running on ASIO**, and never re-probe
  while `engineStatus.activeBackend == asio` (R1 re-entrancy guard).
- **`void setBackend(AudioBackend backend)`** (G2): guard no-op; on switch to
  ASIO, default `asioDriver` to the first enumerated driver if unset; **keep** the
  WASAPI `playbackDeviceId`/`captureDeviceId` dormant (restored on switch back —
  OQ4/E6); `emit`; `_persistAndApply()`.
- **`void setAsioDriver(String driverId)`**: guard no-op; `emit`; `_persistAndApply()`.
- `_engineConfig()` ([audio_setup_cubit.dart:157](lib/audio_setup/cubit/audio_setup_cubit.dart)):
  add `backend: state.backend`, `asioDriver: state.asioDriver`; **force
  `useLoopbackCapture: false` when `state.isAsio`** (E8 — no WASAPI loopback while
  ASIO holds the device).
- `_storedConfig()`: add `backend`, `asioDriver`.
- `_projectFromRepository(hydrateConfig)`: hydrate `backend` from
  `lastConfig?.backend ?? AudioBackend.wasapi`, `asioDriver` from
  `lastConfig?.asioDriver ?? ''`; negotiated reality from
  `engineStatus.activeBackend`.
- **Connectivity (OQ5)**: in `_detectConnectivity`
  ([audio_setup_cubit.dart:251](lib/audio_setup/cubit/audio_setup_cubit.dart)),
  treat `state.isAsio && state.asioDriver.isNotEmpty` as "pinned" so an ASIO driver
  loss can raise the banner.

**7c. Backend selector + driver picker UI** —
[audio_setup_steps.dart](lib/audio_setup/view/audio_setup_steps.dart), `_EngineStep`:
- Top of the step, **only when ASIO is selectable** (`_asioSelectable &&
  asioDrivers.isNotEmpty`): an `_OptionRow` backend selector ("WASAPI" / "ASIO")
  wired to `state.backend` / `cubit.setBackend` (mirror the sample-rate `_Option`
  pattern at [audio_setup_steps.dart:176](lib/audio_setup/view/audio_setup_steps.dart)).
- **When `state.isAsio`**: replace the output `AudioDevicePicker`
  ([audio_setup_steps.dart:167](lib/audio_setup/view/audio_setup_steps.dart)) with
  a single **ASIO driver picker** (reuse `AudioDevicePicker` over
  `state.asioDrivers`, label "<name> · {in} in / {out} out" from the probed
  counts), wired to `state.asioDriver` / `cubit.setAsioDriver`. Hide the separate
  **input** picker in `_InputStep`
  ([audio_setup_steps.dart:236](lib/audio_setup/view/audio_setup_steps.dart)) under
  ASIO (one driver drives all I/O) — show a read-only note instead.
- **Buffer/rate chips**: keep the existing static lists for v1 (driver-derived
  chips deferred); the native `le_asio_pick_buffer` snaps to a valid size at open,
  and the status table shows the negotiated values, so the open never fails over a
  chip choice (E3/E4 satisfied at the *open* level).
- Hide the exclusive-mode toggle
  ([audio_setup_steps.dart:207](lib/audio_setup/view/audio_setup_steps.dart)) under
  ASIO (exclusive is a WASAPI concept).

**7d. Fallback + active-backend status** —
[audio_setup_steps.dart](lib/audio_setup/view/audio_setup_steps.dart),
`_RunningPanel`:
- Show a fallback row **only on mismatch** (G5, mirrors exclusive-fallback):
  `if (state.backend == AudioBackend.asio && state.engineStatus.activeBackend !=
  AudioBackend.asio)` → "ASIO unavailable — running on WASAPI (2 channels)".
- Add a plain "Backend: ASIO / WASAPI" row to the status table.
- **Guard the pre-existing exclusive-fallback row** (from the exclusive-mode PR)
  with `&& !state.isAsio`: under ASIO, `exclusive` intent stays dormant-persisted
  while `exclusiveActive == 0`, which would otherwise spuriously render
  "Shared — device refused exclusive".

**7e. l10n** — add the backend-selector labels, the ASIO driver group label, the
channel-count format ("{in} in / {out} out"), the input-hidden-under-ASIO note,
and the fallback status string to **every ARB file**
([app_en.arb](lib/l10n/arb/app_en.arb) **and**
[app_es.arb](lib/l10n/arb/app_es.arb) — `flutter gen-l10n` flags untranslated
keys). Reuse existing strings where possible.

**Equality/serialization completeness — by class kind (codebase fact):**
| Type | Equality kind | Sites to edit |
|------|---------------|---------------|
| `AudioDevice` (Part 1) | **hand-written** | ctor, `==`, `hashCode`, `toString` |
| `EngineSnapshot` (Part 1) | **hand-written** | ctor, `initial()`, `fromNative`, `==`, `hashAll`, `toString` |
| `EngineStatus` | **Equatable** | ctor, `props`, build site [looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart) |
| `StoredAudioConfig` | **hand-written** | ctor, `==`, `hashCode`, save/load |
| `AudioSetupState` | **Equatable** | ctor, `copyWith`, `props`, derived getters |

## User Flows & Edge Cases

| # | Case | Resolution |
|---|------|------------|
| R1 | ASIO global-state re-entrancy (enumerate while running) | Enumeration is a no-op while `activeBackend == asio`; cubit never re-probes then; Dart test asserts it. |
| G1/G7 | Backend persists end-to-end | `backend`+`asioDriver` through `EngineConfig` (Part 1), `StoredAudioConfig`, `SettingsRepository`, `AudioSetupState`, `_projectFromRepository`, **and** `audio_bootstrap`. |
| G2/E6/OQ4 | Backend switch invalidates device-id meaning | `setBackend` swaps pickers; WASAPI ids kept dormant, never sent to an ASIO open and vice versa. |
| G3/OQ2 | Channel counts before open | Per-driver probe fills `le_device_info`; routing UI gets authoritative counts post-open from the snapshot. |
| G4 | Requested vs ASIO-dictated channel counts | ASIO `open` ignores `cfg` counts, reports the driver's (clamped to 32); `le_engine_configure` uses negotiated counts. |
| G5/OQ1 | Silent fallback hides lost inputs | `active_backend` (Part 1) + `_RunningPanel` fallback row + status row. |
| G6 | Default build (`LOOPY_ENABLE_ASIO=OFF`) | `le_enumerate_asio_drivers` stub → 0 drivers → selector hidden; persisted `backend=asio` falls back via `le_select_backend` + dispatcher retry. |
| E1 | Persisted driver no longer installed | Native open fails → WASAPI fallback; UI surfaces "ASIO unavailable". |
| E2 | Driver busy / single-client (DAW) | Open fails → WASAPI fallback (same path); never a dead engine. |
| E3 | Sample rate refused | Negotiate to driver-current rate; status shows negotiated SR; open never fails over a rate mismatch. |
| E4 | Buffer granularity non-power-of-two / fixed | `le_asio_pick_buffer` snaps to a valid size at open. |
| E5 | Driver exposes > 32 channels | Clamp to `LE_MAX_CHANNELS`; 32-bit masks don't overflow. 18/20 safe. |
| E7 | Heavy live reopen | Teardown `ASIOStop→(clear ptr)→ASIODisposeBuffers→ASIOExit` releases fully before re-init; debounce deferred. |
| E8 | WASAPI loopback irrelevant under ASIO | `useLoopbackCapture` forced off; latency auto-measure relies on `excludedInputMask` only. |
| E9 | Latency display is estimate-based | Keep estimate, label "estimated"; `ASIOGetLatencies` deferred. |
| E10/OQ5 | Connectivity / `device_present` | ASIO sets `device_present=1` running / `0` on failed reopen; ASIO driver counts as "pinned". |
| E11 | Multichannel passthrough (18 ≠ 20) | Per-input monitor masks already handle unequal counts; global `passthrough` monitors input 0 to the stereo pair as today. |
| E12 | Per-device latency key uses `deviceName` | ASIO backend sets `device_name` = driver name, so WASAPI vs ASIO calibration keys stay distinct. |

## Acceptance Criteria

### Functional
- [ ] On a Windows build with `LOOPY_ENABLE_ASIO=ON` and the Focusrite ASIO
      driver, selecting **ASIO** opens the device at the **full 18 in / 20 out**;
      recording/looping/monitoring/routing work across all channels.
- [ ] The ASIO bridge feeds `le_engine_process` correctly: no glitches, correct
      format conversion, correct channel mapping (hardware spike + pure unit tests).
- [ ] The UI shows a **backend selector** (Windows + drivers present); choosing
      ASIO swaps the two pickers for one **ASIO driver picker** showing "18 in /
      20 out"; the routing UI offers all ASIO channels post-open.
- [ ] **Graceful fallback**: ASIO build-off / no driver / missing persisted driver
      / driver busy / init failure all yield working WASAPI audio, never a dead
      engine, and the UI shows the fallback + reason; `active_backend` reports truth.
- [ ] Backend + driver selection **persist** (interactive + auto-start); switching
      back to WASAPI restores the prior device ids.

### Non-Functional
- [ ] **No behavior change on macOS/Linux or the default Windows build** (no ASIO
      code linked, `le_enumerate_asio_drivers` returns 0, selector hidden).
- [ ] **RT contract preserved**: `bufferSwitch` does no allocation/locking;
      `le_engine_process` unchanged.
- [ ] **MIT boundary intact**: GPLv3 ASIO SDK never committed (`.gitignore`d,
      user-supplied `LOOPY_ASIO_SDK_DIR`, OFF by default).
- [ ] **Re-entrancy**: enumeration never probes a driver while ASIO is the running
      backend (R1).

### Quality Gates
- [ ] Native tests green on Windows (MSVC) + macOS/Linux: pure bridge
      conversion/interleave round-trips, `le_asio_pick_buffer` granularity modes.
- [ ] Dart tests: `enumerateAsioDrivers` marshalling + duplex tagging;
      `EngineStatus`/`StoredAudioConfig` new field + forward-compat name guard;
      `AudioSetupCubit` (`setBackend`/`setAsioDriver`/hydration/fallback display/
      no-reprobe-while-asio); audio-setup widget (selector present on Windows w/
      drivers, hidden otherwise; driver-picker swap; fallback row; exclusive row
      suppressed under ASIO).
- [ ] `flutter analyze` clean; app builds on Windows (default + ASIO) + macOS.
- [ ] **Hardware spike** passes on the user's Focusrite before merge.

## Verification (hardware spike — required before merge)

With `LOOPY_ENABLE_ASIO=ON` + `LOOPY_ASIO_SDK_DIR`
([docs/WINDOWS_ASIO.md](docs/WINDOWS_ASIO.md)):
1. **Enumerate + probe**: ASIO driver appears with correct "18 in / 20 out".
2. **Open at full count**: select ASIO, start; snapshot reports 18/20 +
   `active_backend=ASIO`.
3. **Audio integrity**: record from a high input (e.g. 5), play to a high output
   (e.g. 7); correct routing, no glitches, correct pitch/format.
4. **Buffer/rate negotiation**: change buffer + sample rate; clean reopen;
   negotiated values in the status table.
5. **Fallback**: another app holds the driver (or build OFF) → WASAPI fallback +
   surfaced reason; audio still runs at 2 channels.
6. **Persistence**: relaunch → auto-starts back on the ASIO driver.
7. **Re-entrancy**: open the audio-setup panel while ASIO is running → no glitch /
   no driver tear-down (enumeration does not re-probe).

## Out of Scope (deferred follow-ups)
- "Open ASIO Control Panel" button (`ASIOControlPanel`).
- ASIO per-channel **label** exclusion (reuse `win_asio_labels` under ASIO).
- ASIO **reset / hot-swap** handling (`kAsioResetRequest`, device re-open).
- ASIO-reported **latency** (`ASIOGetLatencies`) feeding the latency display.
- A richer **pre-open buffer/rate probe** surfacing exact ASIO-allowed sets as
  chips (incl. `le_asio_buffer_choices`); v1 relies on snap-to-preferred +
  negotiated status.
- Per-driver **format edge cases** beyond common Int32/Int24/Float32.
- **Debouncing** rapid ASIO reopen on successive option changes.
- Backend-**scoped routing** persistence (v1 shares channel indices).

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| The de-interleave/convert bridge has subtle RT bugs | Med | High | Pure `le_deinterleave_in`/`le_interleave_out` + `le_asio_pick_buffer` unit-tested off-thread; hardware spike validates early. |
| ASIO global-state re-entrancy corrupts a live stream | Med | High | R1 contract: never probe while ASIO runs; teardown clears the file-static only after `ASIOStop` returns; Dart test. |
| ASIO driver quirks (format, granularity, SR switching) | Med | Med | Negotiate defensively; snap to driver-preferred; degrade to WASAPI on any init failure. |
| GPLv3 SDK accidentally committed | Low | Critical | OFF by default + `.gitignore` + user-supplied + review (unchanged). |
| Config divergence between cubit and auto-start | Med | Med | Both `_engineConfig` and `audio_bootstrap` add the fields; an acceptance test covers relaunch-into-ASIO. |
| Scope creep into deferred polish | Med | Med | Hard "core end-to-end" boundary; control panel / labels / reset / latency / debounce / `buffer_choices` explicit Out of Scope. |

## Documentation Plan
- [docs/WINDOWS_ASIO.md](docs/WINDOWS_ASIO.md): expand from "label-read-only" to
  document ASIO-as-a-backend — the selector, the flag now also gating the device
  path, the fallback contract, and the R1 re-entrancy rule. Keep the GPLv3/MIT
  section.
- [docs/PROGRESS.md](docs/PROGRESS.md): record the ASIO backend, the
  `active_backend` reporting, and the enumeration symbol.
- Engine header comments on `le_enumerate_asio_drivers`.

## References

- Brainstorm: [2026-06-12-asio-audio-backend-windows-brainstorm-doc.md](docs/brainstorm/2026-06-12-asio-audio-backend-windows-brainstorm-doc.md)
- Part 1 (the seam + struct fields): [2026-06-12-feat-asio-audio-backend-windows-part-1-plan.md](docs/plan/2026-06-12-feat-asio-audio-backend-windows-part-1-plan.md)
- RT core reused unchanged: `le_engine_process` [engine.c:856](packages/loopy_engine/src/engine.c)
- Existing ASIO label probe (mirror its TU shape + SDK usage): [win_asio_labels.cpp](packages/loopy_engine/src/win_asio_labels.cpp)
- Test surface: [engine_internal.h](packages/loopy_engine/src/engine_internal.h); native tests [test_engine_core.c](packages/loopy_engine/src/test/test_engine_core.c)
- Build: [CMakeLists.txt:77](packages/loopy_engine/src/CMakeLists.txt) (ASIO block :90)
- Prior art (requested-vs-negotiated, defensive enum-name read): [2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md](docs/plan/2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md), [settings_repository.dart:120](packages/settings_repository/lib/src/settings_repository.dart)
- Dart layer: [audio_engine.dart](packages/loopy_engine/lib/src/audio_engine.dart), [native_audio_engine.dart](packages/loopy_engine/lib/src/native_audio_engine.dart), [mock_audio_engine.dart](packages/loopy_engine/lib/src/mock_audio_engine.dart), [audio_device.dart](packages/loopy_engine/lib/src/audio_device.dart)
- Domain: [engine_status.dart](packages/looper_repository/lib/src/models/engine_status.dart), [looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart), [settings_repository.dart](packages/settings_repository/lib/src/settings_repository.dart)
- Presentation: [audio_setup_cubit.dart:157](lib/audio_setup/cubit/audio_setup_cubit.dart), [audio_setup_state.dart](lib/audio_setup/cubit/audio_setup_state.dart), [audio_setup_steps.dart:153](lib/audio_setup/view/audio_setup_steps.dart), [audio_bootstrap.dart](lib/app/audio_bootstrap.dart)
- ASIO SDK host API: `AsioDrivers::getDriverNames`, `loadAsioDriver`, `ASIOInit`, `ASIOGetChannels`, `ASIOGetChannelInfo`, `ASIOCanSampleRate`, `ASIOSetSampleRate`, `ASIOGetBufferSize`, `ASIOCreateBuffers`, `ASIOStart`/`ASIOStop`, `ASIODisposeBuffers`, `ASIOExit`, `bufferSwitch`, `ASIOOutputReady`
- ffigen regen gotcha: [PROGRESS.md](docs/PROGRESS.md)
