---
title: WASAPI Exclusive Mode (Full Device Control on Windows)
type: feat
date: 2026-06-12
---

## ✨ WASAPI Exclusive Mode — Full Device Control on Windows

## Overview

Give Windows users **full, exclusive control of their audio interface**: open the
miniaudio duplex device in **WASAPI exclusive mode** (`ma_share_mode_exclusive`)
with OS sample-rate conversion disabled (`wasapi.noAutoConvertSRC`), so audio
bypasses the Windows audio engine/mixer entirely — native format, no resampling,
low latency. This is the MIT-clean path to "full control" (ASIO-as-a-backend was
rejected: miniaudio has no ASIO backend and the SDK is GPLv3; ASIO stays
label-read-only behind the existing opt-in `LOOPY_ENABLE_ASIO` flag).

Exclusive access is **opt-in per the user** via a toggle in audio setup,
**defaulted ON on Windows** (OFF on macOS/Linux to preserve today's behavior),
**persisted** across launches. Because WASAPI exclusive can be refused by the
hardware/OS (unsupported format, or the device is held by another app), the
engine **gracefully falls back to shared mode** so audio never dies, and the
**actually-negotiated mode is reported back through the engine snapshot** so the
UI reflects reality rather than just intent.

## Problem Statement

The engine currently opens the device in miniaudio's **default shared mode** —
[engine.c:1761](packages/loopy_engine/src/engine.c) `ma_device_config_init(ma_device_type_duplex)`
with no `shareMode` set. On Windows that means:

- Audio is mixed/resampled by the Windows audio engine → added latency and
  sample-rate conversion the user did not ask for.
- The device is **shared**, not under the app's exclusive control.

Pro users on RME/MOTU/Focusrite-class interfaces want **exclusive, bit-perfect,
low-latency** access. On Windows the portable way to get that (without ASIO's
licensing/backend cost) is **WASAPI exclusive mode**, which miniaudio supports
natively via `capture.shareMode` / `playback.shareMode` and `wasapi.noAutoConvertSRC`.

This is purely additive: macOS (CoreAudio) and Linux (JACK/PipeWire) keep their
current behavior; the toggle defaults OFF and is not even shown off Windows.

## Decisions Locked (with the user)

| Decision | Choice |
|----------|--------|
| Mechanism | **WASAPI exclusive mode** via miniaudio (NOT ASIO-as-a-backend) |
| Default | Toggle **ON by default on Windows**, OFF on macOS/Linux |
| Failure behavior | **Graceful fallback to shared mode** (audio never dies) |
| Intent vs reality | Persist **intent** (toggle = requested exclusive); report **negotiated** mode separately via the snapshot |
| Off-Windows UI | Toggle **hidden** off Windows (engine flag still exists, defaults OFF) |

## Proposed Solution

Add one boolean of *intent* (`exclusive`) that flows down through every layer to
the native device-open call, and one boolean of *reality* (`exclusive_active`)
that flows back up through the snapshot. The toggle shows/persists intent; a
read-only status line shows the negotiated reality.

**Data flow (down):** UI toggle → `AudioSetupState.exclusive` →
`AudioSetupCubit._engineConfig()` / `_storedConfig()` → `EngineConfig.exclusive`
→ `le_config.exclusive` → `ma_device_config.{capture,playback}.shareMode` +
`wasapi.noAutoConvertSRC`.

**Data flow (up):** native device-open result → `le_snapshot.exclusive_active`
→ `EngineSnapshot.exclusiveActive` → `EngineStatus.exclusiveActive` →
`AudioSetupState.engineStatus` → status line in the running panel.

**Persistence:** the *intent* is stored under a new `audio.exclusive` key
(`StoredAudioConfig.exclusive`). The repository stores/returns the raw value only;
the **platform default for an unset value** (Windows → ON) is resolved in the
presentation layer (cubit + `audio_bootstrap`) via `defaultTargetPlatform`, never
in storage. Auto-start (`audio_bootstrap.dart`) reads and resolves it on launch.

## Technical Approach

Build strictly in dependency order: **Data (C/FFI) → Domain (Dart engine/repo/
settings) → Presentation (cubit/UI)**.

### Layer 1 — Native engine (C)

**1a. `le_config` gains an intent flag** — [loopy_engine_api.h](packages/loopy_engine/src/loopy_engine_api.h):

```c
typedef struct le_config {
  ...
  char capture_device_id[256];
  int32_t exclusive;  /* 1 = request OS-exclusive device access (WASAPI exclusive
                       * mode on Windows). Falls back to shared if unavailable.
                       * No effect where the backend has no exclusive concept. */
} le_config;
```

**1b. `le_snapshot` gains a reality flag** — same header, `le_snapshot`:

```c
  int32_t record_offset_frames;
  int32_t exclusive_active;  /* 1 = the device is actually open in exclusive
                              * mode; 0 = shared (incl. an exclusive request that
                              * fell back). Lets the UI show real vs requested. */
```

**1c. Device open applies exclusive + fallback** —
[engine.c:1761](packages/loopy_engine/src/engine.c) `le_engine_start`:

- After building `cfg`, when `config->exclusive`:
  ```c
  if (config->exclusive) {
    cfg.capture.shareMode  = ma_share_mode_exclusive;
    cfg.playback.shareMode = ma_share_mode_exclusive;
    cfg.wasapi.noAutoConvertSRC = MA_TRUE; /* native rate, no OS SRC */
  }
  ```
- **Graceful fallback:** wrap the `ma_device_init` call. If `config->exclusive`
  and the exclusive init fails, reset the share modes to `ma_share_mode_shared`
  (and clear `noAutoConvertSRC`) and retry once. Track which path succeeded:
  ```c
  int exclusive_active = 0;
  ma_result r = ma_device_init(pContext, &cfg, &engine->device);
  if (r != MA_SUCCESS && config->exclusive) {
    cfg.capture.shareMode = cfg.playback.shareMode = ma_share_mode_shared;
    cfg.wasapi.noAutoConvertSRC = MA_FALSE;
    r = ma_device_init(pContext, &cfg, &engine->device);   /* shared retry */
  } else if (r == MA_SUCCESS && config->exclusive) {
    exclusive_active = 1;
  }
  if (r != MA_SUCCESS) { le_uninit_context(engine); return LE_ERR_DEVICE; }
  ```
  > miniaudio note (header, ~line 8683): exclusive init does **not** auto-fall-back;
  > the caller must reinitialize with shared. The retry above is that.
- Publish the negotiated mode alongside the other post-init `store_i32` calls
  (near [engine.c:1843](packages/loopy_engine/src/engine.c)) into a new atomic
  `engine->a_exclusive_active`, read out in `le_engine_get_snapshot`
  ([engine.c:1925](packages/loopy_engine/src/engine.c)) → `out->exclusive_active`.
- Add the `a_exclusive_active` atomic field to `struct le_engine`
  ([engine_private.h](packages/loopy_engine/src/engine_private.h)) and initialize
  it in `le_engine_configure`/reset paths to 0.

**1d. Factor the only new C *logic* into a pure, testable helper.** Everything
else in 1c is glue around `ma_device_init`, which needs hardware. The decision
"given the requested `exclusive` flag and the result of each init attempt, should
we retry shared / are we exclusive-active / did we fail" is pure. Extract it so
the fallback is unit-tested without a device:

```c
/* Pure share-mode fallback decision, so the retry logic is testable without a
 * device. Given whether exclusive was requested and whether the first
 * (exclusive) init succeeded, decide the outcome. */
typedef enum { LE_SHARE_DONE_EXCLUSIVE, LE_SHARE_RETRY_SHARED,
               LE_SHARE_DONE_SHARED } le_share_decision;
le_share_decision le_decide_share_fallback(int requested_exclusive,
                                           int first_init_ok);
```
Declared in [engine_internal.h](packages/loopy_engine/src/engine_internal.h),
defined in engine.c, and used by `le_engine_start` to drive the retry + set
`exclusive_active`.

**Native tests** — [test_engine_core.c](packages/loopy_engine/src/test/test_engine_core.c):
- `test_decide_share_fallback`: the full truth table — requested+ok →
  DONE_EXCLUSIVE; requested+fail → RETRY_SHARED; not-requested → DONE_SHARED.
  This is the real safety net for the fallback path.
- `le_config.exclusive` / `le_snapshot.exclusive_active` default to 0 (struct
  zero-init smoke test; documents these exist for struct-layout regression, not
  logic).
- Existing `test_enumerate_devices_runs` / lifecycle tests still pass (no
  behavior change when `exclusive == 0`).

### Layer 2 — FFI bindings (regen)

Regenerate after the `le_config` / `le_snapshot` change, per the repo gotcha
([PROGRESS.md](docs/PROGRESS.md)):

```sh
cd packages/loopy_engine
dart run ffigen --config ffigen.yaml
dart format lib/src/generated/loopy_engine_bindings.dart   # required: tall style
```

Verify the generated `le_config` and `le_snapshot` structs expose
`exclusive` / `exclusive_active` and the diff is field-scoped (no whole-file churn).
Run the loopy_engine analyzer/tests **right after regen, before touching the Dart
wrappers**, so a struct-layout surprise surfaces at the FFI boundary rather than
three layers up.

### Layer 3 — Dart engine layer (loopy_engine)

**3a. `EngineConfig`** — [engine_config.dart](packages/loopy_engine/lib/src/engine_config.dart):
add `final bool exclusive` (default `false`), wire it into the constructor,
`writeTo` (`ptr.ref.exclusive = exclusive ? 1 : 0`), `==`, `hashCode`, `toString`.

**3b. `EngineSnapshot`** — [engine_snapshot.dart](packages/loopy_engine/lib/src/engine_snapshot.dart):
add `final bool exclusiveActive` in **all four** sites (missing any breaks
compile or equality):
1. primary constructor: `this.exclusiveActive = false`
2. the `EngineSnapshot.initial()` const constructor's initializer list
3. `EngineSnapshot.fromNative`: `exclusiveActive: native.exclusive_active != 0`
4. `props`

**3c. `MockAudioEngine`** — [mock_audio_engine.dart](packages/loopy_engine/lib/src/mock_audio_engine.dart):
**deterministic rule:** the mock always "succeeds" — its snapshot reports
`exclusiveActive == config.exclusive` (echo intent). This keeps mock/dev runs
predictable. **The fallback-display path (intent ON, reality OFF) is therefore
NOT exercised by the mock** — its widget test drives that branch directly by
constructing an `EngineStatus(exclusiveActive: false)` with `exclusive: true`
(see Layer 6c tests), rather than expecting the mock to simulate a refusal.

**Tests:** unit-test `EngineConfig` (new field in equality/writeTo) and
`EngineSnapshot.fromNative` (the new mapping) in the loopy_engine package tests.

### Layer 4 — Repository + persistence (Domain)

**4a. `EngineStatus`** — [engine_status.dart](packages/looper_repository/lib/src/models/engine_status.dart):
add `final bool exclusiveActive` (default `false`), props; map it where the
repository builds `EngineStatus` from the snapshot
([looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart)):
`exclusiveActive: snapshot.exclusiveActive`.

**4b. `StoredAudioConfig`** — [settings_repository.dart](packages/settings_repository/lib/src/settings_repository.dart):
add `final bool exclusive` (optional, `this.exclusive = false` — a **storage**
default only, not the platform default), update the hand-written `==` and
`hashCode` (`Object.hash` arg list); new key
`static const _audioExclusiveKey = 'audio.exclusive';`
- `saveAudioConfig`: `await _store.setBool(_audioExclusiveKey, value: config.exclusive);`
- **The repository stays platform-agnostic — do NOT import `dart:io`.** Add a
  **nullable** read so callers can distinguish "never set" from "explicitly false":
  ```dart
  Future<bool?> loadAudioExclusive() async => _store.getBool(_audioExclusiveKey);
  ```
  and keep `loadAudioConfig`'s `StoredAudioConfig.exclusive` as the stored value
  (`?? false`) for the round-trip equality model, while the *platform default for
  an unset value* is resolved in the presentation layer (Layers 5 & 6) via
  `defaultTargetPlatform == TargetPlatform.windows`. This keeps OS policy out of
  storage and makes the default **test-overridable** with
  `debugDefaultTargetPlatformOverride` (which `Platform.isWindows` is not).

  > Rationale (both plan reviewers, Critical): `Platform.isWindows` in a pure
  > persistence layer mixes policy into storage and can't be overridden in unit
  > tests. `defaultTargetPlatform` is the same primitive the UI gate (Layer 6c)
  > and widget tests already use, so intent and rendering agree.

**Tests:** extend [settings_repository_test.dart](packages/settings_repository/test/settings_repository_test.dart)
for round-trip of `exclusive` (save true → load true; unset → `null` from
`loadAudioExclusive` / `false` from the stored struct). The *platform-default*
behavior is tested in the cubit (Layer 6), not here.

### Layer 5 — Auto-start path

[audio_bootstrap.dart](lib/app/audio_bootstrap.dart): resolve the platform
default at the single call site and pass it into `EngineConfig(...)`:

```dart
final exclusive = await settings.loadAudioExclusive()
    ?? (defaultTargetPlatform == TargetPlatform.windows);
... EngineConfig(..., exclusive: exclusive)
```

No UI here — the negotiated mode is surfaced later when the cubit hydrates from
the live snapshot (Layer 6), closing the "auto-start has no UI" gap.

### Layer 6 — State, Cubit, UI (Presentation)

**6a. `AudioSetupState`** — [audio_setup_state.dart](lib/audio_setup/cubit/audio_setup_state.dart):
add `final bool exclusive` (intent) to the constructor (default `false` — a plain
field default; the *platform* default is applied once in the cubit, below),
`copyWith`, `props`. Negotiated reality is read from
`engineStatus.exclusiveActive` (already in state via `engineStatus`).

**6b. `AudioSetupCubit`** — [audio_setup_cubit.dart](lib/audio_setup/cubit/audio_setup_cubit.dart):
- **Single source of the platform default.** Define
  `static bool get _defaultExclusive => defaultTargetPlatform == TargetPlatform.windows;`
  and use it as the `??` fallback wherever a persisted/last value is absent. (This
  is the *only* place the rule lives — the repository and `audio_bootstrap` both
  use the same `defaultTargetPlatform` primitive; no double-default.)
- New `void setExclusive({required bool exclusive})` mirroring `setMonitorInput`:
  guard no-op, `emit(copyWith(exclusive:...))`, `_persistAndApply()` (reopen when
  running — exclusive engages/disengages immediately, possibly negotiating shared).
- `_engineConfig()`: add `exclusive: state.exclusive`.
- `_storedConfig()`: add `exclusive: state.exclusive`.
- `_projectFromRepository(hydrateConfig)`: hydrate `exclusive` from
  `lastConfig?.exclusive ?? _defaultExclusive` (intent), same pattern as
  `monitorInput` but with the platform-aware fallback instead of `current.exclusive`.
  The negotiated reality comes from `engineStatus.exclusiveActive`, unchanged.

> **Cold-open hydration quirk (document, not a bug):** `_projectFromRepository`
> reads `_repository.lastEngineConfig`, which is `null` until the engine has
> started. So before first start the toggle shows `_defaultExclusive`, not a
> previously-saved `false`. This matches how every existing field (`monitorInput`,
> sample rate, …) behaves on a cold open; the persisted value takes over once the
> engine runs (auto-start applies it immediately on launch).

**6c. UI** — [audio_setup_steps.dart](lib/audio_setup/view/audio_setup_steps.dart):
- Add an **Exclusive mode** `_Toggle` (mirror the monitor-input toggle at
  [audio_setup_steps.dart:231](lib/audio_setup/view/audio_setup_steps.dart)),
  wired to `state.exclusive` / `cubit.setExclusive`. **Only render it on Windows**
  (`if (defaultTargetPlatform == TargetPlatform.windows)`), so macOS/Linux are
  visually and behaviorally unchanged. Place it in the output/engine step (device
  control), subtitle e.g. "Take exclusive control of the interface (lower latency,
  bypasses the Windows mixer)".
- **Surface fallback only when it happens (less noise, fewer strings):** in
  `_RunningPanel`, show a single status row *only* on a mismatch —
  `if (state.exclusive && !state.engineStatus.exclusiveActive)` →
  "Shared — device refused exclusive". When exclusive engaged (the common,
  expected case) show nothing extra. This drops the symmetric "Mode: Exclusive"
  string the first draft budgeted.
- l10n: add the toggle title/subtitle and the single fallback-status string to
  **every ARB file** ([app_en.arb](lib/l10n/arb/app_en.arb) **and**
  [app_es.arb](lib/l10n/arb/app_es.arb) — `flutter gen-l10n` flags untranslated
  keys), used via `context.l10n`. **Reuse the existing `toggleOn`/`toggleOff`**
  strings (already used for `monitorInput` at audio_setup_steps.dart:267); do not
  add new on/off keys.

**Tests:**
- Cubit test ([audio_setup_cubit_test.dart](test/audio_setup/cubit/audio_setup_cubit_test.dart)):
  `setExclusive` emits + persists + reopens when running; `_engineConfig`/
  `_storedConfig` carry `exclusive`; hydration restores intent. **Platform default
  (moved here from the repo):** with `debugDefaultTargetPlatformOverride =
  TargetPlatform.windows` an unset persisted value hydrates `exclusive: true`; with
  macOS it hydrates `false`.
- Widget test ([audio_setup_view_test.dart](test/audio_setup/view/audio_setup_view_test.dart)):
  the toggle is present and flips on Windows (`debugDefaultTargetPlatformOverride`),
  **hidden on macOS/Linux**; the running panel shows the fallback status row **only**
  when intent is exclusive but `engineStatus.exclusiveActive == false` (drive this
  by seeding a state with `exclusive: true` + `EngineStatus(exclusiveActive: false)`),
  and shows nothing extra when exclusive engaged.

**Immutability/equality completeness (do not miss any site).** Each new field is
optional with a safe default; update every equality/serialization surface:
| Type | Sites to edit |
|------|---------------|
| `EngineConfig` | ctor, `writeTo`, `==`, `hashCode`, `toString` |
| `EngineSnapshot` | ctor, `initial()`, `fromNative`, `props` |
| `EngineStatus` | ctor, `props`, build site at [looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart) |
| `StoredAudioConfig` | ctor (optional), `==`, `hashCode` |
| `AudioSetupState` | ctor, `copyWith`, `props` |

## Edge Cases & Resolutions (from flow analysis)

| Case | Resolution |
|------|------------|
| Exclusive init fails (unsupported format **or** device busy) | Uniform single retry in **shared** at the same requested SR/buffer. Audio never dies. `exclusive_active = 0`. |
| Both exclusive and shared init fail | `LE_ERR_DEVICE` — same as today's reopen failure; cubit surfaces `openDeviceFailed`. (Restore-previous-good is pre-existing behavior, out of scope.) |
| Auto-start (no cubit) falls back | Negotiated mode rides the snapshot; the cubit reads `engineStatus.exclusiveActive` when audio-setup opens — no reliance on persisted intent for reality. |
| Toggle vs reality on fallback | Toggle **stays ON** (persisted intent) so exclusive re-engages on the next reopen (e.g. after the blocking app closes); a separate read-only status shows "Shared". |
| Unsupported SR/buffer under exclusive | Covered by the shared fallback (no pre-filtering of SR/buffer options in v1). |
| Device hot-swap / replug | The standard reopen path applies the same exclusive→shared fallback to the new device. |
| macOS/Linux | Toggle **hidden**; `exclusive` defaults OFF; CoreAudio hog mode is never engaged → behavior byte-for-byte unchanged. |
| Existing Windows users upgrading | Unset `audio.exclusive` defaults to ON on Windows; the graceful fallback guarantees their setup still runs. Documented as an intentional, safe default change. |
| Persistence | Persist **intent** only, never the fallback result, so exclusive can re-engage. |
| Cold open (engine not yet started) | Toggle shows the platform default (`_defaultExclusive`), not the persisted value — `lastEngineConfig` is null until start. Consistent with every existing field (`monitorInput` etc.); persisted intent applies as soon as the engine runs (auto-start does so on launch). |

## Acceptance Criteria

### Functional
- [ ] On Windows, with the toggle ON, the engine opens the device in WASAPI
      exclusive mode (verified: lower/representative latency, native rate, mixer
      bypassed) on the user's interface.
- [ ] When exclusive is unavailable (format unsupported or device busy), the
      engine **falls back to shared** and keeps running; `exclusive_active` reports `0`.
- [ ] The audio-setup UI shows the **negotiated** mode (exclusive vs shared
      fallback), distinct from the toggle's requested state.
- [ ] The toggle defaults **ON on Windows**, is **hidden on macOS/Linux**, and is
      **persisted** across launches (including the auto-start path).
- [ ] Toggling exclusive while running reopens the device so it takes effect now.
      A reopen that negotiates **shared** (exclusive refused) counts as success —
      a fallback-on-toggle is not a failure.

### Non-Functional
- [ ] **No behavior change on macOS/Linux** (toggle hidden, `exclusive` OFF, no
      hog mode); default builds elsewhere unchanged.
- [ ] **FFI**: `le_config`/`le_snapshot` grow by one int32 each; bindings
      regenerated with `dart format`; no unrelated binding churn.
- [ ] **Degradation**: the engine never errors solely because exclusive was
      requested — it falls back.

### Quality Gates
- [ ] Native tests green on Windows (MSVC) + macOS/Linux (`exclusive == 0` path
      unchanged).
- [ ] Dart tests: `EngineConfig`, `EngineSnapshot`, `StoredAudioConfig`,
      `AudioSetupCubit`, audio-setup widget — all cover the new field/flow.
- [ ] `flutter analyze` clean; app builds on Windows + macOS.

## Out of Scope (future)
- Pre-filtering SR/buffer choices to exclusive-supported values (query supported
  formats). v1 relies on the shared fallback.
- Differentiating "device busy (another app)" from "hardware unsupported" in the
  error/status copy.
- Auto-retry exclusive when a contending app releases the device.
- Re-running the latency measurement automatically on every mode change (the
  status shows the negotiated mode; an explicit re-measure remains user-driven).
- CoreAudio "hog mode" on macOS / any exclusive concept on Linux.
- ASIO as an audio backend (remains label-read-only behind `LOOPY_ENABLE_ASIO`).

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Exclusive init fails on the user's interface for common SR/buffer | Med | Med | Graceful shared fallback; surface negotiated mode so it's visible, not silent. |
| `noAutoConvertSRC` + a picked SR the device can't do natively kills the open | Med | Med | Same fallback path; (future) pre-filter SR options. |
| Default-ON changes existing Windows users' audio behavior | High (Win upgraders) | Low | Fallback guarantees audio runs; documented; intent is recoverable/toggleable. |
| ffigen regen churns the whole bindings file | Med | Low | Run `dart format` per the repo gotcha; review field-scoped diff. |
| Snapshot field addition shifts struct layout / stale bindings | Low | Med | Regenerate bindings; native tests assert struct usage; FFI is hand-loaded but generated structs must match. |
| `const` state default can't read `Platform` | Low | Low | Resolve the platform default at hydration via `_defaultExclusive` (`defaultTargetPlatform`), not in the `const` constructor; the state field default stays a plain `false`. |

## Documentation Plan
- [docs/WINDOWS_ASIO.md](docs/WINDOWS_ASIO.md) cross-reference: note WASAPI
  exclusive is the default "full control" path; ASIO stays label-only.
- [docs/PROGRESS.md](docs/PROGRESS.md): record the exclusive-mode capability,
  the negotiated-mode reporting, and the Windows-default/​off-elsewhere rule.
- Engine header comments on `le_config.exclusive` / `le_snapshot.exclusive_active`.

## References

- Device open (shared today): [engine.c:1761](packages/loopy_engine/src/engine.c)
- Snapshot publish/read: [engine.c:1843](packages/loopy_engine/src/engine.c), [engine.c:1925](packages/loopy_engine/src/engine.c)
- `le_config` / `le_snapshot`: [loopy_engine_api.h:189](packages/loopy_engine/src/loopy_engine_api.h), [loopy_engine_api.h:268](packages/loopy_engine/src/loopy_engine_api.h)
- `EngineConfig`: [engine_config.dart](packages/loopy_engine/lib/src/engine_config.dart)
- `EngineSnapshot.fromNative`: [engine_snapshot.dart:345](packages/loopy_engine/lib/src/engine_snapshot.dart)
- `EngineStatus`: [engine_status.dart](packages/looper_repository/lib/src/models/engine_status.dart)
- Repo builds status: [looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart)
- `StoredAudioConfig` + save/load: [settings_repository.dart:7](packages/settings_repository/lib/src/settings_repository.dart)
- Cubit config/persist/hydrate: [audio_setup_cubit.dart:140](lib/audio_setup/cubit/audio_setup_cubit.dart)
- State: [audio_setup_state.dart](lib/audio_setup/cubit/audio_setup_state.dart)
- Toggle UI pattern (monitor input): [audio_setup_steps.dart:231](lib/audio_setup/view/audio_setup_steps.dart)
- Auto-start: [audio_bootstrap.dart](lib/app/audio_bootstrap.dart)
- ffigen regen gotcha: [PROGRESS.md:37](docs/PROGRESS.md)
