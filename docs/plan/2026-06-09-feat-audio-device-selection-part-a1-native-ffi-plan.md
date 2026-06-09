# feat: audio device enumeration + presence (native + FFI) — PR A1

Type: **feat** · Status: **planned** · Created: 2026-06-09

Part **A1** of the audio-device/routing-UX bundle. Sub-split of the original
"PR A" (see
[2026-06-09-feat-audio-device-and-routing-ux-plan.md](2026-06-09-feat-audio-device-and-routing-ux-plan.md)).
A1 lands the **native + FFI + `loopy_engine` Dart** layer only: enumerate
devices, pin a device by id, and report device presence. **No app-visible
behavior changes** — the codebase stays fully working and green after A1.

A2 (reconnect supervisor + cubit + device picker + banner) builds on this.

---

## Dependencies

- **The multichannel routing PR** (`feat/multichannel-routing`) must be merged
  first — A1 extends `le_config`, `le_snapshot`, and the FFI bindings that PR
  also touches.

## Why split this out

PR A originally bundled every architectural layer (native C → FFI →
`loopy_engine` → repository → settings → cubit → app shell, ~600–850 LOC). The
native/FFI half is reviewed for RT-safety and C correctness; the Dart-async half
for concurrency and recovery. A1 isolates the former so it can be approved on its
own merits, leaving the tree in a working state (engine can enumerate and report
presence; existing behavior unchanged).

## Codebase context & conventions

VGV layered monorepo. Native engine in `packages/loopy_engine/src/` (RT-safe
audio callback; control→audio via the SPSC ring; audio→control via per-field
`_Atomic` snapshots). FFI bindings regenerated with
`dart run ffigen --config ffigen.yaml` after any `loopy_engine_api.h` change.
Native tests: `clang … src/test/test_engine_core.c …` (device-free). Dart tests
via the absolute `/Users/Tomas/development/flutter/bin/flutter`. App reaches the
engine only through `package:looper_repository` (no `loopy_engine` import in
`lib/`) — **A1 adds nothing to `lib/`.** Keep every gate green: native
`ALL PASSED`, `flutter analyze`, app suite, macOS build.

---

## Scope

### Native (`loopy_engine_api.h` / `engine.c`)

- [ ] **Device enumeration.** Add
      `le_device_info { char id[256]; char name[256]; int32_t is_default; }` and
      `le_enumerate_playback_devices(le_device_info* out, int32_t max, int32_t* count)`
      / `le_enumerate_capture_devices(...)` using a `ma_context`
      (`ma_context_get_devices`). Keep the two native calls separate (playback vs
      capture) — match the miniaudio API shape; the Dart layer exposes them as
      two typed calls rather than one merged list with an `isInput` flag.
- [ ] **Device pinning.** `le_config`: add `char playback_device_id[256]` /
      `char capture_device_id[256]` (empty ⇒ system default). In
      `le_engine_start`, when set, resolve the id and set
      `cfg.playback.pDeviceID` / `cfg.capture.pDeviceID`, reusing the existing
      explicit-`ma_context` path already used for loopback capture.
- [ ] **Disconnect detection.** Set `cfg.notificationCallback`; on a
      `stopped` / `rerouted` / device-lost notification, store an atomic
      `a_device_present` (1 = present, 0 = lost). The callback is RT-adjacent —
      **store the atomic only, no work.** **No reconnection logic in native**
      (RT contract): recovery is driven from Dart in A2.
- [ ] **Snapshot.** Add `device_present` (0/1) to `le_snapshot`. Keep `running`
      unchanged. These are **distinct signals**: a pinned device can be lost
      while the engine object still "runs" until restart. Document this in the
      header comment so a reviewer doesn't conflate `device_present` with
      `running` / the Dart-derived `isConnected`.

### FFI

- [ ] Regenerate bindings (`dart run ffigen --config ffigen.yaml`) after the
      `loopy_engine_api.h` changes. Rebuild macOS to confirm native/Dart struct
      agreement.

### Dart (`packages/loopy_engine`)

- [ ] `EngineConfig`: add `playbackDeviceId` / `captureDeviceId` (default `''`).
      Match the existing camelCase field convention (`sampleRate`,
      `bufferFrames`).
- [ ] `AudioDevice { String id; String name; bool isDefault; bool isInput }`
      value object (small, but the picker in A2 needs a typed list and it carries
      the `isDefault`/`isInput` discriminators cleanly).
- [ ] `AudioEngine.enumerateDevices()` exposing inputs **and** outputs — backed
      by the two separate native calls; tag each result with `isInput`.
- [ ] `EngineSnapshot.devicePresent`.

> A1 deliberately stops here. The repository (`devices()`,
> `EngineStatus.devicePresent`), the reconnect supervisor, persistence, the
> cubit, and all UI land in **A2**.

## Mock filenames (tests)

- `packages/loopy_engine/src/test/test_engine_core.c` — extend: enumeration
  smoke (a `ma_context` returns ≥0 devices without crashing) and config-id
  plumbing (a non-empty `playback_device_id` is resolved/applied without error;
  empty falls back to default).
- `packages/loopy_engine/test/engine_snapshot_test.dart` — `devicePresent`
  parses from the snapshot struct.
- `packages/loopy_engine/test/engine_config_test.dart` — `playbackDeviceId` /
  `captureDeviceId` default to `''` and round-trip into the native config.
- `packages/loopy_engine/test/audio_device_test.dart` — `AudioDevice`
  equality/fields.

## Acceptance criteria

- [ ] `enumerateDevices()` returns the host's playback + capture devices with
      correct `isDefault` / `isInput` flags.
- [ ] Starting the engine with a pinned `playbackDeviceId` opens that device;
      empty string opens the system default (unchanged behavior).
- [ ] `EngineSnapshot.devicePresent` reflects 1 while the device is live and
      flips to 0 on a device-lost notification — verified manually by unplugging
      (presence flips; no crash; no reconnection attempted yet).
- [ ] No changes under `lib/`; existing app behavior identical.
- [ ] Native `ALL PASSED`; `flutter analyze` clean; app suite green; macOS
      builds.

## Risks / notes

- **FFI struct changes** ⇒ ffigen regen + macOS rebuild to confirm struct
  agreement (see the FFI macOS build notes / `Package.swift` `process()` + the
  CocoaPods fallback).
- **Notification callback is RT-adjacent.** Only an `_Atomic` store is allowed
  inside it; anything else risks the audio thread.
- Enumeration uses a transient `ma_context` and must not disturb a running
  device — verify it can be called while the engine is started.
