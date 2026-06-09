# feat: full multichannel per-track I/O routing

Type: **feat** · Status: **ready to build** · Created: 2026-06-09

Lets each looper track record from a chosen hardware **input** channel and play
to chosen hardware **output** channel(s) on a multichannel interface — instead
of the current fixed stereo (record one input, play to the stereo mix).

This is the largest remaining feature ("Slice 4" of the recent epic) and the
only one that **needs the user's audio interface plugged in** to verify
end-to-end. Build it in the phases below; ship each phase as its own commit and
keep every phase green (native tests + `flutter analyze` + app suite) before
moving on.

---

## Decisions (locked by the user)

- **Routing depth: full device channels.** Open the interface with all its
  input and output channels; route each track independently.
- **Track buffers become mono.** Each track records exactly one input channel
  into a mono buffer and is mixed into one or more output channels. This is the
  standard looper routing model and is simpler than per-track multichannel
  buffers. (Current buffers are stereo — this is a migration, see Phase 2.)
- Capture and playback channel counts may differ (e.g. 2-in / 4-out), so the
  config carries **separate** `input_channels` and `output_channels`.
- Sensible default routing preserves today's behaviour: a new track records
  from input channel 0 and plays to output channels 0 **and** 1 (stereo pair).

## Acceptance criteria

1. The engine opens the device with the requested input and output channel
   counts (clamped to device capability and `LE_MAX_CHANNELS`); the snapshot
   reports the negotiated counts.
2. Each track has an `input_channel` (record source) and an `output_mask`
   (bitmask of destination output channels), settable at runtime via RT-safe
   commands and reflected in the snapshot.
3. Recording captures `in[frame*ch_in + input_channel]`; playback adds the
   track's mono sample to every output channel set in `output_mask`.
4. Default routing (input 0 → outputs 0+1) keeps existing single-/multi-track
   loop behaviour audibly identical on a stereo device; all existing native and
   Dart tests still pass (updated only where the buffer-shape change requires).
5. Latency compensation, loop multiples (#4), undo/redo, the loop-viz tap, and
   transport reset all keep working with mono track buffers.
6. The repository and a routing UI expose per-track input/output selection;
   routing is persisted per track.
7. `flutter analyze` clean; native `ALL PASSED`; full app suite green; macOS
   app builds.

---

## Codebase context & conventions

VGV layered monorepo. Data → Repository → Bloc/Cubit → Presentation.

- **Native engine**: `packages/loopy_engine/src/engine.c` (+ `loopy_engine_api.h`,
  `loop_clock.c`, `lockfree_ring.c`). RT contract: the audio callback
  (`le_engine_process` / `data_callback`) does **no** malloc/lock/syscall/
  unbounded-loop. Control→audio commands go through the SPSC ring
  (`le_push` + `apply_command`); audio→control state is published via per-field
  `_Atomic` snapshots (`get_snapshot`). One capturer at a time (chained
  hand-off). Buffer pools + undo/redo stacks are owned by the **control thread**;
  the audio thread only reads `pool[a_live]`.
- **Native tests** (deterministic, device-free — the real safety net):
  ```sh
  cd packages/loopy_engine
  clang -std=c11 -Wall -Wextra -I src -I src/miniaudio \
    src/test/test_engine_core.c src/engine.c src/lockfree_ring.c \
    src/loop_clock.c src/miniaudio_impl.c \
    -framework CoreAudio -framework AudioToolbox -framework AudioUnit \
    -framework CoreFoundation -lpthread -lm -o /tmp/loopy_core_tests
  /tmp/loopy_core_tests
  ```
- **Regenerate FFI bindings** after editing `loopy_engine_api.h` (struct/array
  sizes are baked into the generated Dart):
  `cd packages/loopy_engine && dart run ffigen --config ffigen.yaml`
- **Dart/Flutter tests**: the very_good_cli MCP test tool is broken here; run via
  the absolute path `/Users/Tomas/development/flutter/bin/flutter test`
  (the lint hook blocks bare `flutter test`).
- **macOS build**:
  `/Users/Tomas/development/flutter/bin/flutter build macos --debug --flavor development -t lib/main_development.dart`
- App constructs the engine via `LooperRepository.withNativeEngine()` (no direct
  `loopy_engine` import in `lib/`). `EngineConfig`/`EngineResult`/`EngineStatus`
  reach `lib/` via `package:looper_repository`.
- Current relevant constants: `LE_MAX_TRACKS = 8`, `LE_MAX_CHANNELS = 2`
  (`loopy_engine_api.h`). Per-track buffers are currently `channels`-wide
  (stereo); record write index and playback read index multiply position by
  `ch`.

---

## Phase 1 — Native: separate I/O channel counts + device open

Goal: open the device with full input and output channel counts, no routing yet
(behaviour unchanged). Smallest change that lets the rest build on real
multichannel I/O.

Tasks:
- `loopy_engine_api.h`: raise `LE_MAX_CHANNELS` to `32`. In `le_config`, replace
  `channels` with `input_channels` and `output_channels` (or add the two and
  keep `channels` as a deprecated alias mapped to both — prefer the clean
  replacement). Add `input_channels` / `output_channels` to `le_snapshot`.
- `engine.c`:
  - Store `a_in_channels` / `a_out_channels` atomics; set them in
    `le_engine_configure` from the device-negotiated capture/playback channel
    counts (`ma_device_config` duplex: `cfg.capture.channels`,
    `cfg.playback.channels`). Clamp each to `LE_MAX_CHANNELS`.
  - In `le_engine_process` / `data_callback`, stop assuming a single `ch`:
    use `ch_in` for the input frame stride and `ch_out` for the output frame
    stride. The looper mixing, monitoring (passthrough), level metering, and the
    loopback latency harness must all use the correct stride. Keep per-track
    buffers stereo for now (Phase 2 migrates them) — record/playback continue to
    use the existing default path but read input channel 0 and write the stereo
    pair of the OUTPUT buffer.
  - `EngineConfig.writeTo` / `le_config` field rename ripples to
    `engine_config.dart` (Phase 3) — keep the native struct authoritative.
- `EngineConfig` callers in native tests: `le_engine_configure(e, sr, channels,
  max)` — update the signature to take input + output channel counts (or keep a
  convenience wrapper for tests). Update `make_configured_engine`.
- Regenerate FFI bindings.

Acceptance: native `ALL PASSED` with the new I/O-stride process loop on a
stereo (2-in/2-out) config; snapshot reports input/output channel counts.

Watch-outs: the loopback harness writes a calibration pulse to output and reads
it back from input — it must target valid channels under the new strides. Mono
input merge (`merge_to_mono`) still applies to the capture side.

## Phase 2 — Native: mono track buffers + per-track routing

Goal: the actual routing. Migrate per-track buffers to **mono** and route each
track independently.

Tasks:
- Per-track buffer pool becomes mono: allocate `max_loop_frames * 1` floats
  (drop the `* channels`); record/overdub/playback index by `pos` only (no
  `* ch`). Update: `finalize_master`, `finalize_new_track`, the record/overdub
  write (`buf[t][w]`), playback read (`buf[t][seg_base + pos]`), undo/redo
  buffer copies (`memcpy` sizes), the control-thread zeroing in
  `le_engine_record`, and the loop-viz per-track tap.
- Add per-track atomics `a_input_channel` (int, default = track index clamped to
  `ch_in-1`, or 0) and `a_output_mask` (uint32 bitmask, default = bit 0 | bit 1).
- Process loop:
  - Record: `sample = mono_input ? mono : in[f*ch_in + clamp(input_channel)]`;
    write `buf[t][w] = sample` (mono). Latency-compensated as today.
  - Playback/overdub: read `loopsample = buf[t][seg_base + pos]` (mono); for
    each output channel `c` with bit `c` set in `output_mask`,
    `out[f*ch_out + c] += loopsample * vol[t]` (respect mute).
  - Monitoring: keep the existing live passthrough, but route the monitored
    input to the same output channels as the armed/selected track's mask, or
    keep a simple global monitor (decide during build; simplest is global
    passthrough of input ch i → output ch i for shared channels).
- Commands + API: `LE_CMD_SET_INPUT_CHANNEL`, `LE_CMD_SET_OUTPUT_MASK` in the
  ring + `apply_command`; `le_engine_set_input_channel(engine, channel, value)`
  and `le_engine_set_output_mask(engine, channel, mask)` exports. Validate
  channel/mask against the current I/O channel counts.
- Snapshot: add `input_channel` and `output_mask` to `le_track_snapshot`.
- Native tests (`test_engine_core.c`):
  - Record from a chosen input channel: configure 2-in, set track input_channel
    = 1, feed a 2-channel input where ch1 carries the signal, verify the loop
    plays it back.
  - Output mask: set output_mask to a single channel, verify the sample appears
    only on that output channel and is silent on others.
  - Regression: default routing still mixes input 0 → outputs 0+1 (existing
    multitrack/latency/multiples tests adapted to mono buffers).
- Regenerate FFI bindings.

Acceptance: native `ALL PASSED` including the new routing tests; default routing
keeps prior tests green (adapted for mono).

## Phase 3 — Dart data + repository

- `loopy_engine` (`lib/src/`):
  - `engine_config.dart`: `inputChannels` / `outputChannels` (replace
    `channels`); `writeTo` maps to the renamed native fields.
  - `engine_snapshot.dart`: add `inputChannels` / `outputChannels` to
    `EngineSnapshot`, and `inputChannel` / `outputMask` to `TrackSnapshot`
    (`fromNative` reads the new struct fields); update `==`/`hashCode`/`toString`
    and `EngineSnapshot.initial`.
  - `audio_engine.dart` interface + `native_audio_engine.dart`:
    `setInputChannel({required int channel, required int value})` and
    `setOutputMask({required int channel, required int mask})`.
  - `loopy_engine.dart` exports as needed.
- `looper_repository`:
  - `Track` model: add `inputChannel` and `outputMask`.
  - `_project`: map snapshot routing into `Track`; surface device
    `inputChannels`/`outputChannels` on `EngineStatus`.
  - `LooperRepository`: `setInputChannel` / `setOutputMask` passthroughs.
  - Update the repository fake under `packages/looper_repository/test/helpers`.
- Tests: `engine_snapshot_test.dart`, `looper_repository_test.dart` (routing
  passthroughs + projection), repo fake.

## Phase 4 — App: routing UI + persistence

- `LooperBloc`: events `LooperInputChannelChanged(channel, value)` and
  `LooperOutputMaskChanged(channel, mask)` → repository.
- Audio setup: let the user pick (or auto-detect) input/output channel counts;
  show the negotiated counts in the status panel. `AudioSetupCubit` +
  `EngineConfig` plumbing for `inputChannels`/`outputChannels`.
- Per-track routing control: a compact routing panel reachable from the track
  (e.g. in the Big Picture settings page, a "Routing" section per track, or a
  long-press/secondary action on a track column). Pick input source (dropdown of
  available input channels) and output destinations (toggle chips per output
  channel). Keep it simple and consistent with the existing settings styling.
- Persist routing per track in `settings_repository`
  (`saveTrackInputChannel` / `saveTrackOutputMask` keyed by channel) and restore
  on launch (apply to the engine, mirroring the latency-offset restore in
  `tryAutoStartEngine`).
- Tests: bloc events, the routing UI widget test, settings round-trip.

## Phase 5 — On-hardware validation (manual, with the user)

- Plug in the multichannel interface. Verify: a track records from a selected
  physical input and plays to selected physical outputs; switching routing live
  takes effect; default routing matches prior stereo behaviour. Update test
  counts + `docs/PROGRESS.md`, then open the PR.

---

## Risks / notes

- The mono-buffer migration touches every record/playback/undo/viz site in
  `engine.c`; do Phase 2 carefully and lean on the native tests after each edit.
- Monitoring with routing is the fuzziest part — keep it simple first (global
  passthrough) and refine only if needed.
- FFI struct layout changes twice (Phase 1 and Phase 2) — regenerate bindings
  each time and rerun the macOS build to confirm native/Dart struct agreement.
- Don't break the loopback latency harness (it assumes channel 0 round-trip).
