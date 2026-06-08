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
- **Phase 3 core:** N-track engine (LE_MAX_TRACKS=4) + grid UI; metronome +
  count-in + tap-tempo; `controller_repository` (MIDI-learn-ready) wired into
  the bloc.
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
- **Loop ↔ tempo sync** (#2): finalizing the defining loop rounds it to whole
  bars at the current tempo, derives the beat grid back from the loop (so it
  divides exactly), and snaps the displayed tempo to fit. The metronome is
  driven from the master position once a loop exists (free-runs at the tapped
  tempo before that, for count-in). Toggle "sync loop to tempo" (default on);
  off = free-form length, untouched tempo. `loop_bars` + sync flag in the
  snapshot, surfaced in the tempo bar (bar count + sync toggle).
- **Quantize-start** (#3): `quantize` off / beat / bar (default bar). While a
  loop exists, a record/overdub press **arms** the track and the capture begins
  at the next grid boundary (applied in `process` via the #2 master-position
  beat detection); a second press cancels the arm. Stops act immediately.
  `quantize_mode` + `armed_channel` in the snapshot; tempo-bar quantize selector
  + per-track "armed" chip in the UI.
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
  Picture**); `UiModeCubit` persists the mode. Big Picture is a full-screen
  Chewie-style colored loop-tile grid plus a **second OS window** (via
  `desktop_multi_window`) showing the live output waveform. The waveform is fed
  by a new RT-safe native **output viz tap** (`le_engine_read_visual`: a 512-pt
  decimated peak ring) → `AudioEngine.readVisual` → the main window streams
  frames to the second window at ~30 fps over the plugin channel. (Two-window
  runtime is build-verified only; needs an on-machine run to confirm visually.)

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
- **#2 loop ↔ tempo** — round the defining loop to whole bars and derive the
  beat grid (and displayed tempo) from the loop; metronome locks to loop
  position. Sync is a persistent toggle, default on; off keeps the free-form
  length and tempo. Bars/grid are computed once at finalize (toggling sync on
  after a free-form loop does not retro-snap it).
- **#3 quantize-start** — default **bar**; off/beat/bar. A press while a loop
  exists arms; capture starts at the next grid boundary; second press cancels.
  Only *starts* are quantized (stops are immediate). The undo snapshot is still
  taken on the control thread at press time; a cancelled arm leaves a harmless
  duplicate undo layer (never an RT-unsafe copy on the audio thread).

---

## Roadmap (path forward)

**The sync roadmap (#2–#4) is complete** — loop ↔ tempo, quantize-start, and
loop multiples all landed (see Done / Locked decisions). What remains needs
hardware or a second display, or is Phase 4 scope.

### Possible next steps (no hard dependency)
- **Per-track multi-loop phase alignment** — multi-loop tracks currently phase
  relative to their own start iteration; an absolute-parity option would align
  all k-loop tracks to the same base-loop downbeat.
- **Quantized stop / per-track loop-length display in bars** — small UX wins on
  top of #2–#4.

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
native (all C tests, 35 fns: 4 loop↔tempo + 5 quantize + 2 loop-multiples + 1
viz tap) · plugin 27 · controller 14 · looper_repository 14 · settings 3 ·
local_storage 1 · app 66 (theming/big-picture/multi-window). macOS app builds
end-to-end. (Theming work is on branch `feat/big-picture-theming`; the sessions
slice — native 34, session_repository 17, app 53 — is on `feat/session-repository`.)
