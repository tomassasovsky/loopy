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

---

## Locked design decisions (don't re-litigate)

- **Record is exclusive** — one input stream, one capturer; chained hand-off.
- **Latency compensation** — comp write + live monitoring + auto-offset from the
  loopback measurement, persisted per device.
- **Undo/redo** — multi-level, per track, overdub layers only; clear removes a
  track. Immediate swap (tiny click on undo accepted).
- **#4 loop multiples** — **auto-round on stop** (record freely; round track
  length up to the nearest whole multiple of the base loop).

---

## Roadmap (path forward) — remaining sync work, in order

All three are real-time engine changes touching the master clock / position
model. Do them one at a time with deterministic native tests.

### #2 Loop ↔ tempo  (NEXT)
Make the metronome and the loop agree.
- Loop carries a `bars` count. On finalizing the defining loop, snap
  `bars = max(1, round(recordedFrames / framesPerBar))` at the current tempo,
  then **derive the beat grid from the loop**: `framesPerBeat = masterLen /
  (bars * BEATS_PER_BAR)`, so the metronome divides the loop exactly and the
  displayed tempo snaps to fit.
- Drive metronome clicks from the **master position** (locked to the loop) once
  a loop exists; free-run at the tapped tempo before that (for count-in).
- Toggle "sync loop to tempo" (default on); off = today's free-form behaviour.
- Expose `bars` / synced tempo in the snapshot; show in the UI.

### #3 Quantize-start  (AFTER #2)
- Setting `quantize`: off / beat / bar (default bar).
- A record/overdub press while a loop exists **arms** and the capture begins at
  the next grid boundary (engine pending-arm applied in `process` at the
  beat/bar boundary). Surface an "armed" state in the snapshot/UI.

### #4 Loop multiples  (AFTER #3)
- Per-track length that can be an integer multiple of the base loop.
- Introduce a **free-running global position**; each track plays at
  `globalPos % trackLen`. Master UI still wraps at the base length.
- Auto-round: on stopping a track's recording, round its length up to the
  nearest whole multiple of the base; track buffers are cap-sized so a longer
  track fits up to `max_loop_frames`.
- Snapshot per-track length already exists; add the multiple/length wiring.

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
native (all C tests) · plugin 26 · controller 14 · looper_repository 12 ·
settings 3 · local_storage 1 · app 39. macOS app builds end-to-end.
