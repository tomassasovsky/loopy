# loopy_engine

Native low-latency **duplex audio engine** for Loopy, exposed to Dart over FFI.

This is the data-layer foundation of the loopstation: a hand-written
[miniaudio](https://miniaud.io)-based engine that owns the real-time signal path
on the OS audio callback thread, with a typed Dart API for control and state.

> **Phase 1 scope.** Today the engine does duplex passthrough, level metering, a
> loopback round-trip **latency harness**, and ships the lock-free command-ring
> foundation. Recording, overdub, looping, and multi-track mixing arrive in later
> phases on top of this same boundary.

## The FFI boundary contract

```text
Dart (UI isolate)                         Native engine (C)
─────────────────                         ─────────────────
AudioEngine API  ──► le_engine_post_command ──► SPSC ring ─┐
                                                           ▼
snapshot() ◄── le_engine_get_snapshot ◄── atomics ◄── AUDIO CALLBACK THREAD
```

- **Commands** flow Dart → engine through a single-producer/single-consumer
  lock-free ring (`lockfree_ring.[ch]`), drained at the top of each callback.
- **State** flows engine → Dart through per-field atomics, read by
  `snapshot()` on a render-rate timer. Readers never dereference engine memory
  from the audio thread.
- Dart **never** blocks or allocates on the audio thread.

### Real-time safety rules (audio callback)

The audio callback (`le_engine_process` in `src/core/engine_process.c`) must
never:

- `malloc`/`free`, take a lock/mutex, or perform file/socket I/O;
- run an unbounded loop or call back into Dart.

All buffers are pre-allocated before the device starts. State is published with
relaxed atomic stores; control commands arrive only through the SPSC ring.

## Layout

The native sources under `src/` are grouped by concern:

| Path | Role |
| --- | --- |
| `src/core/loopy_engine_api.h` | The C ABI consumed by ffigen (POD + opaque handle). |
| `src/core/` | The portable engine, split into per-concern TUs: `engine.c` (control-thread core + shared helpers), `engine_process.c` (the audio-thread TU — `le_engine_process`, transport, `apply_command`), `engine_fx.c` (effects DSP), `engine_commands.c` (control-thread setters), `engine_devices.c`, `engine_snapshot.c`, `engine_session.c`, `engine_convert.c`, `engine_miniaudio.c` (the miniaudio backend), plus the `lockfree_ring` / `loop_clock` primitives and the private/internal headers. |
| `src/platform/` | Per-OS device seams (`engine_apple.c` / `engine_linux.c` / `engine_windows.c`). |
| `src/midi/` | Native MIDI seam: `midi.c` (portable core) + per-OS backends. |
| `src/asio/` | Windows ASIO backend (`win_asio_device` / `win_asio_labels`). |
| `src/miniaudio/` | Vendored miniaudio (MIT-0 / public domain) + `miniaudio_impl.c`. |
| `src/test/` | Native unit tests + `run_native_tests.sh`. |
| `lib/src/audio_engine.dart` | `AudioEngine` interface (the test seam). |
| `lib/src/native_audio_engine.dart` | FFI-backed implementation. |
| `lib/src/generated/` | ffigen output — do not edit by hand. |

Every `src/` subdirectory holding headers is on the compiler include path
(`src/CMakeLists.txt`), so the sources use flat `#include "engine_private.h"`
regardless of which folder they live in.

## Building

The plugin builds automatically as part of `flutter run`/`flutter build` for
macOS, Windows, and Linux:

- **macOS** — compiled via `macos/loopy_engine.podspec` (CoreAudio).
- **Linux** — `linux/CMakeLists.txt` → `src/CMakeLists.txt` (ALSA/PulseAudio/JACK
  loaded at runtime by miniaudio).
- **Windows** — `windows/CMakeLists.txt` → `src/CMakeLists.txt` (WASAPI; links
  `ole32`, `winmm`).

C11 is required for `<stdatomic.h>`.

### Regenerate FFI bindings

```sh
dart run ffigen --config ffigen.yaml
```

Requires `libclang` (ships with Xcode / LLVM).

### Run the native core tests

`src/test/run_native_tests.sh` builds and runs both native suites (engine + MIDI)
with the right per-OS toolchain flags and source/include paths:

```sh
bash src/test/run_native_tests.sh
```

It expects "ALL PASSED" from each suite. The engine source list it compiles
mirrors `src/CMakeLists.txt`; keep the two in sync when adding a TU.

## Usage

```dart
final engine = NativeAudioEngine();
final result = engine.start(const EngineConfig(sampleRate: 48000));
if (result.isOk) {
  final snap = engine.snapshot(); // levels, frame counters, latency
  engine.measureLatency();        // requires an output→input loopback
}
engine.stop();
engine.dispose();
```

## Latency measurement

`measureLatency()` emits a single full-scale impulse on the output and counts
the frames until it returns on the input, publishing the round-trip time via
`EngineSnapshot.measuredLatencyMs` (valid when `latencyState == done`). It
requires a **physical output→input loopback** (loopback cable or virtual
loopback device). With no loopback the harness reports `timeout`.
