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

The `data_callback` in `src/engine.c` must never:

- `malloc`/`free`, take a lock/mutex, or perform file/socket I/O;
- run an unbounded loop or call back into Dart.

All buffers are pre-allocated before the device starts. State is published with
relaxed atomic stores; control commands arrive only through the SPSC ring.

## Layout

| Path | Role |
| --- | --- |
| `src/loopy_engine_api.h` | The C ABI consumed by ffigen (POD + opaque handle). |
| `src/engine.c` | Device lifecycle + the real-time audio callback. |
| `src/lockfree_ring.[ch]` | SPSC command ring (wait-free push/pop). |
| `src/miniaudio_impl.c` | The single miniaudio implementation translation unit. |
| `src/miniaudio/miniaudio.h` | Vendored miniaudio (MIT-0 / public domain). |
| `src/test/test_engine_core.c` | Native unit tests (ring + lifecycle). |
| `lib/src/audio_engine.dart` | `AudioEngine` interface (the test seam). |
| `lib/src/native_audio_engine.dart` | FFI-backed implementation. |
| `lib/src/generated/` | ffigen output — do not edit by hand. |

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

```sh
clang -std=c11 -Wall -Wextra -I src -I src/miniaudio \
  src/test/test_engine_core.c src/engine.c src/lockfree_ring.c src/miniaudio_impl.c \
  -framework CoreAudio -framework AudioToolbox -framework AudioUnit \
  -framework CoreFoundation -lpthread -lm -o /tmp/loopy_core_tests
/tmp/loopy_core_tests
```

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
