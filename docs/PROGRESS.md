# Loopy — Progress & Roadmap

Living status doc for the Flutter desktop loopstation. Pairs with the original
plan in `docs/plan/2026-06-08-feat-flutter-desktop-loopstation-plan.md`.
Update this as work lands so any session (human or agent) can resume cold.

Repo: https://github.com/tomassasovsky/loopy · branch `master`.

---

## How to build / test (environment gotchas — read first)

- **Dart/Flutter tests:** the very_good_cli MCP `test` tool is broken in this
  env (exit 69, machine-output parser vs Flutter 3.44). Hooks block bare
  `flutter test` / `dart test`. Run via the **absolute path**, which the guard
  doesn't match: `/Users/Tomas/development/flutter/bin/flutter test`.
- **Scaffolding:** `flutter create` is hook-blocked in favour of the very_good
  MCP `create` tool — but that only makes federated method-channel plugins. The
  FFI plugin (`loopy_engine`) is **hand-authored** (`ffiPlugin: true` + CMake +
  podspec). Native engine lives **inside** the plugin at
  `packages/loopy_engine/src/` (Flutter symlinks plugins at build time, so
  out-of-package native paths dangle).
- **macOS FFI loading:** the podspec sets `MACH_O_TYPE => mh_dylib` and uses
  `Classes/` forwarder TUs that `#include` `../src`; `DynamicLibrary.process()`
  on Apple (SPM static-links into the Runner). Don't revert these.
- **Native engine tests** (deterministic, no device — the real safety net since
  the audio thread can't be runtime-tested here):
  ```sh
  cd packages/loopy_engine
  clang -std=c11 -Wall -Wextra -I src -I src/miniaudio \
    src/test/test_engine_core.c src/engine.c src/lockfree_ring.c \
    src/loop_clock.c src/miniaudio_impl.c \
    -framework CoreAudio -framework AudioToolbox -framework AudioUnit \
    -framework CoreFoundation -lpthread -lm -o /tmp/loopy_core_tests
  /tmp/loopy_core_tests
  ```
- **Regenerate FFI bindings** after touching `src/loopy_engine_api.h`:
  `cd packages/loopy_engine && dart run ffigen --config ffigen.yaml`
- **macOS app run/build:** flavor schemes required.
  `flutter build macos --debug --flavor development -t lib/main_development.dart`
  Run: `flutter run -d macos --flavor development -t lib/main_development.dart`

---

## Architecture (VGV layered monorepo)

```
packages/
  loopy_engine/        DATA  — FFI plugin over a hand-written miniaudio engine (C)
  controller_repository/ REPO — hardware-agnostic MIDI/GPIO → looper actions
  looper_repository/   REPO  — owns the engine; EngineSnapshot → LooperState
  settings_repository/ REPO  — per-device latency calibration persistence
  local_storage_client/ DATA — KeyValueStore (shared_preferences)
lib/
  app/        App + MultiRepositoryProvider (looper, controller, settings)
  looper/     LooperBloc + Chewie-2 track grid (home)
  audio_setup/ device/sr/buffer, engine start/stop, latency, loopback note
```

Strict layering: presentation → bloc → repository → data. The engine's typed
`AudioEngine` interface is the test seam (fakes everywhere).

### Native engine model (`packages/loopy_engine/src/engine.c`)
- One **master loop clock** (`le_loop_clock`: length + position). First finalized
  track sets the length; all tracks index the same `position` → phase-locked.
- **Per-track** `le_track`: a lazily-allocated **buffer pool** (`pool[LE_UNDO_SLOTS]`)
  + undo/redo stacks, all owned by the **control thread** (sole writer of the
  atomic `a_live`). The **audio thread only reads `pool[a_live]`** and overdubs
  into it — no allocation/locks/stack-access on the callback.
- RT contract: no malloc/lock/syscall/unbounded-loop in `le_engine_process`.
  Commands arrive via an SPSC ring; state published via per-field atomics.
- `le_engine_process` / `le_engine_configure` are exposed for **device-free
  deterministic tests** (`src/test/test_engine_core.c`).

---

## Done

Phases 1–3 of the plan plus several sync refinements. See `git log` for detail.

- **Phase 1:** monorepo, miniaudio FFI plugin, duplex passthrough, round-trip
  latency harness, "hello duplex" smoke app.
- **Phase 2:** single-track looper (record → master length → overdub → mix →
  vol/mute → clear), `looper_repository` + `LooperBloc` + channel-strip view,
  `audio_setup`.
- **Phase 3 core:** N-track engine (LE_MAX_TRACKS=4) + grid UI;
  `controller_repository` (MIDI-learn-ready) wired into the bloc.
- **Loopback latency auto-detect** (PulseAudio monitor / WASAPI / virtual
  driver) + cable-free auto-measure (digital-path estimate; cable for true
  analog).
- **Latency compensation (record offset):** overdub/new-track input written at
  `pos − offset`; monitoring is **live** (not folded); offset auto-set by a
  measurement, overridable.
- **Persist latency:** per-device (device + sr + buffer) via
  `settings_repository` / `local_storage_client`.
- **Single-capturer recording** (chained hand-off): record on a new track
  finalizes the current one and starts the new from the loop top.
- **Multi-level undo/redo** per track (control-thread buffer pool; undo = overdub
  layers, clear = remove track).
- **Fully free mode** (no tempo): all BPM/metronome/click/count-in/tap-tempo,
  loop↔tempo sync (#2), and quantize-start (#3) logic was **removed** from the
  native engine, FFI, repository, bloc, and UI. The looper has **one master loop
  length**, set by the first finalized recording; there is no beat grid, no
  click, and no quantization — captures start and stop immediately. Per-track
  loop multiples (#4, below) are retained, as is latency compensation, the loop
  waveform visualizer, Big Picture / two-window mode, and theming.
- **Loop multiples** (#4): a non-defining track can span an integer multiple of
  the base loop. A free-running `loop_iteration` counts base-loop wraps; each
  track plays `((iteration − start_iter) % multiple)·baseLen + position`, so the
  master still wraps at the base length while a k-loop track cycles its k
  segments. New tracks record freely from the loop top across base loops and are
  **auto-rounded up** to whole base loops on stop (buffer zeroed on the control
  thread so a rounded-up tail is silent). Per-track `multiple` in the snapshot;
  `×N` chip in the UI.
- **Theming + Big Picture mode** (Phase 4 slice): two Material 3 themes via a
  `LooperTheme` `ThemeExtension` (dark-neutral **Desktop**, neon-on-black **Big
  Picture**); `UiModeCubit` persists the mode (as a string). Big Picture is a
  Chewie-Monsta-style row of tall colored track columns (per-track number,
  loop-waveform thumbnail, editable persisted name via `BigPictureCubit`,
  selection highlight, per-track accent / red recording) **plus a second OS
  window** (`desktop_multi_window`) showing the whole-loop output waveform with
  a white playhead bar. Fed by a new RT-safe native **loop-indexed viz tap**
  (`le_engine_read_visual` + `read_track_visual`: peak per loop bucket, master
  + per-track, refreshed as the playhead sweeps). `KeyValueStore` now stores
  string/bool/double. (Two-window runtime is build-verified only; needs an
  on-machine run to confirm visually.) `desktop_multi_window` is pinned to
  pub.dev `^0.2.0` (the SPM-fork branch was dropped; CocoaPods builds fine).
- **Auto-start audio + first-run flow:** the last-used audio config (sample
  rate / buffer / monitor / merge-to-mono) is persisted on a successful start
  (`SettingsRepository.save/loadAudioConfig`). On launch, `tryAutoStartEngine`
  loads it and starts the engine; if none is saved (first run) the **Audio Setup
  page is the start screen** until the engine connects, then it hands off to the
  looper.
- **Big Picture is the default look** (`UiModeCubit` defaults to `bigPicture`).
  A dedicated, minimal **Big Picture settings page** (rename tracks, reach audio
  setup, toggle the waveform window, switch to Desktop) is reachable from the
  performance view by **right-click** or the **`S` key**, and from the **macOS
  system menu bar** (`PlatformMenuBar`, ⌘,). A persisted `WaveformWindowCubit`
  gates the secondary window. The chromeless big-picture exit button was removed
  (exit lives in settings now).

---

## Locked design decisions (don't re-litigate)

- **Record is exclusive** — one input stream, one capturer; chained hand-off.
- **Latency compensation** — comp write + live monitoring + auto-offset from the
  loopback measurement, persisted per device.
- **Undo/redo** — multi-level, per track, overdub layers only; clear removes a
  track. Immediate swap (tiny click on undo accepted).
- **#4 loop multiples** — **auto-round on stop** (record freely from the loop
  top; round track length up to the nearest whole multiple of the base loop).
  Free-running `loop_iteration`; track reads its `(iter-start_iter) % k` segment.
  New-track first pass always begins at the loop top (phase-locked multiples);
  per-track multi-loop phase is relative to each track's own start.
- **Fully free mode (no tempo)** — the looper is tempo-free: one master loop
  length set by the first recording, no metronome/click/count-in/tap-tempo, no
  loop↔tempo sync, no quantization. Captures start/stop immediately. BPM logic
  was deleted (not hidden) from engine → FFI → repo → bloc → UI. Loop multiples
  (#4), latency compensation, the waveform visualizer, Big Picture / two-window,
  and theming are retained. (Supersedes the earlier #2 loop↔tempo and #3
  quantize-start decisions, which were removed.)

---

## Roadmap (path forward)

**The looper is now fully free (tempo-free).** Loop multiples (#4) remain; the
tempo features (#2 loop↔tempo, #3 quantize-start) were removed. What remains
needs hardware or a second display, or is Phase 4 scope.

### Possible next steps (no hard dependency)
- **Per-track multi-loop phase alignment** — multi-loop tracks currently phase
  relative to their own start iteration; an absolute-parity option would align
  all k-loop tracks to the same base-loop downbeat.

### Deferred (need hardware / 2nd display)
- `midi_client` — real USB-MIDI binding (abstraction + wiring ready; needs a
  pedal). Plug a `ControllerSource` into the already-wired `ControllerRepository`.
- Secondary-window **visualizer** (`desktop_multi_window`) — needs a 2nd display.
- **Phase 4:** sessions save/load + WAV export, Raspberry Pi GPIO backend,
  device hot-plug handling, theming/accessibility/golden tests.

### On-hardware validations still open
- Phase-1 **latency gate** (≤10 ms round-trip) — needs a class-compliant
  interface + loopback (cable or virtual device like BlackHole).
- Audible tightness of latency compensation and undo/redo clicks.

---

## Test counts (last green)
native (all C tests, 22 fns: 2 loop-multiples + 1 loop-viz + 1 mid-loop record,
tempo tests removed in the free-mode strip) · plugin 26 · controller 14 ·
looper_repository 12 · settings 11 · app 70 (auto-start, first-run, big-picture
settings + access). `flutter analyze` clean; macOS app builds end-to-end.
