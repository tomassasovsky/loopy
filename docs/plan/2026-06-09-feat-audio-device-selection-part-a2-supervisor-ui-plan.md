# feat: device reconnect supervisor + selection UI — PR A2

Type: **feat** · Status: **planned** · Created: 2026-06-09

Part **A2** of the audio-device/routing-UX bundle. Sub-split of the original
"PR A" (see
[2026-06-09-feat-audio-device-and-routing-ux-plan.md](2026-06-09-feat-audio-device-and-routing-ux-plan.md)).
A2 lands the **Dart-async + app** layer: surface devices through the repository,
auto-recover a pinned device, let the user pick/persist a device, and show
connect/disconnect banners.

---

## Dependencies

- **PR A1** ([part-a1 plan](2026-06-09-feat-audio-device-selection-part-a1-native-ffi-plan.md))
  must be merged first — A2 consumes `AudioEngine.enumerateDevices()`,
  `EngineConfig.playbackDeviceId` / `captureDeviceId`, and
  `EngineSnapshot.devicePresent`.

## Codebase context & conventions

App reaches the engine only through `package:looper_repository`. The repository
exposes a **single** broadcast stream, `looperState`, projected from snapshots
([looper_repository.dart:55](../../packages/looper_repository/lib/src/looper_repository.dart)).
`AudioSetupCubit` already takes `LooperRepository` + `SettingsRepository`,
already listens to `looperState`
([audio_setup_cubit.dart:22](../../lib/audio_setup/cubit/audio_setup_cubit.dart)),
and already persists audio config via `settings_repository`. Persistence flows
through **one aggregate** `StoredAudioConfig`: `tryAutoStartEngine` restores via
`settings.loadAudioConfig()`
([audio_bootstrap.dart:12](../../lib/app/audio_bootstrap.dart)) and the cubit
saves via `saveAudioConfig(StoredAudioConfig(...))`. Existing config keys
(`audio.sample_rate`, `audio.buffer_frames`, …) all live inside
`StoredAudioConfig`
([settings_repository.dart:108](../../packages/settings_repository/lib/src/settings_repository.dart)).
Keep every gate green: native `ALL PASSED`, `flutter analyze`, app suite, macOS
build.

---

## Scope

### Repository (`looper_repository`)

- [ ] Surface `devices()` (delegates to `AudioEngine.enumerateDevices()`) and
      `EngineStatus.devicePresent`. Keep `isConnected`/`isRunning` semantics
      **unchanged** — `devicePresent` is the new disconnect signal, derived from
      the snapshot and exposed on `EngineStatus`.
- [ ] **Reconnect supervisor** (Dart control side, never in the audio callback):
      when a **pinned** device goes absent (`devicePresent == 0`) then reappears
      in enumeration, stop + restart the engine on it. Poll enumeration on a
      timer; all recovery logic stays on the Dart side.
- [ ] **No new repository stream.** Do **not** add a separate
      `Stream<DeviceEvent>` / sealed `DeviceLost`/`DeviceRestored` hierarchy —
      that would be a second source of truth about device liveness with no
      precedent in this codebase. `devicePresent` rides the existing
      `looperState` projection; the cubit derives lost/restored **transitions**
      by diffing it (see below).

### App — state (`AudioSetupCubit` / state)

- [ ] Add `deviceId` selection state (System default + the enumerated list) for
      playback and capture.
- [ ] **Persistence via `StoredAudioConfig`, not loose keys.** Add
      `playbackDeviceId` / `captureDeviceId` fields to `StoredAudioConfig`
      (empty = system default); persist on selection through the existing
      `saveAudioConfig(...)` path; restore on launch through the existing
      `loadAudioConfig()` → `tryAutoStartEngine` flow. **No parallel
      `audio.playback_device_id` keys.**
- [ ] **Derive device events in the cubit.** The cubit already listens to
      `looperState`; track previous `devicePresent` and emit a transient
      banner-trigger in cubit state when it goes 1→0 (`DeviceLost`, with the
      pinned device name) or 0→1 (`DeviceRestored`). No new stream type.

### App — UI

- [ ] **Device picker** in the audio-setup section (dropdown: "System default" +
      enumerated devices, separate for input/output).
- [ ] **In-app banner/snackbar** at the app shell so it shows in both layouts:
      `ScaffoldMessenger` / `MaterialBanner` driven from cubit state —
      "… disconnected — trying to reconnect" on lost, "… reconnected" on
      restored.

## Mock filenames (tests)

- `packages/looper_repository/test/looper_repository_test.dart` — reconnect
  supervisor against a `FakeAudioEngine` emitting lost→restored: asserts a
  stop+restart on the pinned device when it reappears; no restart for the system
  default; no restart while still absent.
- `packages/settings_repository/test/settings_repository_test.dart` —
  `StoredAudioConfig` round-trips `playbackDeviceId` / `captureDeviceId` (empty
  default).
- `lib/audio_setup/cubit/audio_setup_cubit.dart` → `test/audio_setup/cubit/audio_setup_cubit_test.dart`
  — device selection updates state + persists; `devicePresent` 1→0 / 0→1
  transitions raise the lost/restored banner triggers.
- `test/audio_setup/view/audio_setup_view_test.dart` — picker renders the
  enumerated list and "System default"; selecting persists.
- `test/app/view/app_test.dart` — banner widget test: `MaterialBanner` shows on
  lost and clears on restored.

## Acceptance criteria

- [ ] Pick a device in the picker → it opens; selection persists across restart
      via `StoredAudioConfig`.
- [ ] Unplug the pinned device → banner ("disconnected — trying to reconnect") +
      engine marked not-present.
- [ ] Replug → supervisor auto-reopens the **same** device + "reconnected"
      banner.
- [ ] "System default" still works and is never auto-restarted on transient
      loss.
- [ ] Native `ALL PASSED`; `flutter analyze` clean; app suite green; macOS
      builds.

## Risks / notes

- **Device hot-plug is the fiddliest path.** Keep all reconnection logic on the
  Dart side (poll enumeration), never in the audio callback. Test the supervisor
  with a `FakeAudioEngine`, not real hardware.
- **Restart races:** stop+restart must be debounced so a flapping device does
  not thrash the engine. Guard against overlapping restart attempts.
- **Banner in both layouts:** mount the `ScaffoldMessenger` at the shell, not
  inside a single page, or the banner is lost on navigation.
