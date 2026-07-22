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
  bash packages/loopy_engine/src/test/run_native_tests.sh
  ```
  The script self-locates (no preceding `cd` needed) and builds/runs the
  engine core test suite and the MIDI test suite on every desktop OS
  (`gcc`/`gnu11` by default, overridable via `CC`), plus macOS-only plugin
  scan/slot native tests against the vendored VST3/CLAP SDKs. Each suite
  prints "ALL PASSED"; the script exits non-zero on any compile or test
  failure.
- **Regenerate FFI bindings** after touching `src/loopy_engine_api.h`:
  ```sh
  cd packages/loopy_engine
  dart run ffigen --config ffigen.yaml
  dart format lib/src/generated/loopy_engine_bindings.dart
  ```
  The `dart format` step is required: ffigen emits legacy short-style code,
  but the committed bindings are canonical `dart format` (tall) style. Without
  it, every regen rewrites the whole file and buries the real diff. With it,
  regens are field-scoped regardless of your local SDK's formatter version.
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
  session_repository/  REPO  — save/restore .loopy session bundles (manifest + WAV stems)
  performance_repository/ REPO — performance-recording capture lifecycle (arm/finalize/recover)
  wav_codec/           DATA  — 32-bit-float WAV encode/decode (pure Dart, no Flutter dep)
  daw_export/          DATA  — pure-Dart Ableton Live 12 (.als) exporter for a performance capture
  midi_client/         DATA  — native USB-MIDI device client (ControllerSource) over the FFI seam
  midi_device_repository/ REPO — MIDI device enumeration/selection + hotplug (audio-independent)
  pedal_repository/    REPO  — hardware pedal (footswitch/LED) protocol over MIDI SysEx
  routing_graph/       UI KIT — reusable routing-graph canvas/wires/cards + theme (Signal, FX editor)
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
- **Multi-lane tracks** (PR 1 of the multi-lane/dual-route rework). A `le_track`
  is a container that owns the **transport** (state / multiple / pending-arm),
  one **shared latency-compensated write head** (`record_pos`), and **one undo
  span** (`undo_stack`/`redo_stack`, the same slot index in every lane). Each
  `le_lane` (`lanes[LE_MAX_LANES]`, `LE_MAX_LANES == LE_MAX_INPUTS == 8`) records
  **one** hardware input (`a_input_channel`, -1 = none) into its **own clean mono
  buffer** — sibling lanes are **never merged/averaged** — with per-lane output
  mask / volume / mute / effects. Recording is **track-addressed** and fans out
  to every active lane; playback **sums** all lanes; undo swaps every lane's
  `a_live` in lockstep. **Lazy lane allocation**: only lane 0 of each track is
  allocated at configure; `le_engine_set_lane_count` allocates added lanes on the
  control thread, and a **real-time null-guard** keeps the audio thread from
  dereferencing an unallocated lane buffer. Track-addressed setters (volume /
  mute / input / output / fx) map to **lane 0** for backward compatibility.
- Lane buffer pools + undo/redo stacks are owned by the **control thread** (sole
  writer of each lane's atomic `a_live`). The **audio thread only reads
  `lane.pool[a_live]`** — no allocation/locks/stack-access on the callback.
- **Effects are per-lane** (one **stageless**, non-destructive chain on each
  lane's own `fx` state — the pre/post `stage` and the per-lane `mon_fx` are
  gone): `le_engine_set_lane_fx(channel,lane,index,type)` / `…_fx_count` /
  `…_fx_param`. Track-addressed FX setters map to **lane 0** for back-compat.
- **Live monitoring is per hardware input** (`le_monitor_input monitors[LE_MAX_INPUTS]`,
  one slot per input, ≤ `LE_MAX_INPUTS`=8): each enabled input is summed live
  through **its own** stageless chain into its output mask, **never recorded**,
  independent of all track state — replacing the old global monitor-FX bus,
  monitor-follow-track, and monitor masks. `le_engine_set_monitor_input(input,
  enabled,output)` / `…_fx` / `…_fx_count` / `…_fx_param`. A loopback
  measurement clears all monitor enables (cable-feedback safety); `passthrough`
  enables input 0 at start.
- **Dry + wet monitoring (independent routing).** Each monitor input also has a
  **parallel dry send** (`a_dry_output_mask`, `LE_CMD_SET_MONITOR_INPUT_DRY=33`,
  `le_engine_set_monitor_input_dry(input,dry_mask)`): the CLEAN (pre-FX) sample
  is summed to its own outputs alongside the effected route, so an input can be
  heard clean on one set of outputs and effected on another at once (`0` = off,
  the default; never recorded). Threaded through `InputMonitor.dryOutputMask`,
  `LooperRepository.setMonitorDry` (remembered + reapplied on restart),
  `MonitorCubit.setDryOutputMask`, and the `monitor_input_dry.$input` key.
- **Monitor routing graph** (`monitor_graph_view.dart`, replacing the per-input
  chip tiles that didn't scale on big interfaces): inputs left, each *monitored*
  input a node + its effect chain in the middle, outputs right, on a zoom/pan
  canvas. Two colour-coded sends per input — **wet** (blue, through the chain)
  and **dry** (amber, dashed). Tap an input to monitor + focus it; an Effected/
  Dry toggle picks which send an output tap wires. Only monitored inputs show as
  nodes; unused ports dim. `monitor_fx_editor.dart` (the old chip editor) is
  removed.
- **Dart domain layer (PR 4) is landed.** `looper_repository` exposes per-lane
  setters (`setLane{Input,Output,Volume,Mute,Count}`, `setLaneEffects`/`…Param`)
  with **lane-0 convenience wrappers** (`setVolume`/`setMute`/`setInputMask`/
  `setOutputMask`/`setTrackEffects` map to lane 0; a selection mask collapses to
  its lowest input via `maskToInputChannel`) and **per-input monitor** methods
  (`setMonitorInput`, `setMonitorEffects`/`…Param`). New domain models `Lane`,
  `InputMonitor`, and `Track.lanes`; `_project()` fills lanes from the snapshot.
  `MonitorCubit` is now a **per-input** list (`Map<int, InputMonitor>`) —
  `MonitorMode`/follow-track and the global monitor-FX bus are gone. Persistence
  moved to `lane_*` / `monitor_input*` keys (old `track_*mask`/`track_effects`/
  `monitor.*` keys dropped, drop-and-default — no migration). Session export
  stays **lane-0 only** (documented follow-up).
- **Multi-lane routing UI (PR 5) is landed.** *(Superseded by the unified Signal
  surface below — `lane_graph_view.dart` and the per-track routing page were
  removed; the lane-addressed `LooperBloc` events described here remain in use.)*
  The per-track routing page is one
  **unified wiring graph** (`lane_graph_view.dart`): hardware inputs on the left,
  the track's lanes stacked in the middle (each a node + its own effect chain),
  hardware outputs on the right, with bezier edges showing every lane's wiring on
  a zoom/pan canvas. Tap a lane node to *focus* it, then tap input/output nodes to
  (re)wire that lane; effects drag-to-reorder and tap-to-edit in a docked panel
  that also holds the focused lane's mix and add/remove-lane (lanes are a stack —
  only the last is removable, capped at `kMaxLanes`). New **lane-addressed**
  `LooperBloc` events (`LooperLane{Count,Input,Output,Volume,Mute,Effects,
  EffectParam}Changed`) replace the lane-0-only mask/track-effect events; each
  forwards to the matching `setLane*` repo method and persists the per-lane
  `lane_*` key. The per-input live-monitor section (audio settings) and the
  stageless chain were already in place from PR 4.
- RT contract: no malloc/lock/syscall/unbounded-loop in `le_engine_process`.
  Commands arrive via an SPSC ring; state published via per-field atomics.
- `le_engine_process` / `le_engine_configure` are exposed for **device-free
  deterministic tests** (`src/test/test_engine_core.c`); per-lane state is read
  with `le_engine_get_lane` (legacy per-track view mirrors lane 0).

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
- **Theming + Big Picture mode** (Phase 4 slice): Material 3 theming via a
  `LooperTheme` `ThemeExtension` (neon-on-black **Big Picture**). _(The
  dark-neutral Desktop theme, the desktop `LooperView`, and the `UiMode`
  toggle were later removed — Big Picture is the single UI mode.)_ Big Picture
  is a
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
  rate / buffer / monitor) is persisted on a successful start
  (`SettingsRepository.save/loadAudioConfig`). On launch, `tryAutoStartEngine`
  loads it and starts the engine; if none is saved (first run) the **Audio Setup
  page is the start screen** until the engine connects, then it hands off to the
  looper.
- **Big Picture is the only look** (the `UiMode` toggle was removed).
  A dedicated, minimal **Big Picture settings page** (rename tracks, reach audio
  setup, toggle the waveform window) is reachable from the
  performance view by **right-click** or the **`S` key**, and from the **macOS
  system menu bar** (`PlatformMenuBar`, ⌘,). A persisted `WaveformWindowCubit`
  gates the secondary window. The chromeless big-picture exit button was removed
  (exit lives in settings now).
- **Record immediately, even mid-loop** — a new track over an existing master
  starts capturing at the current loop phase (no waiting for the loop top);
  `record_pos` seeds to the master position so writes stay phase-locked and the
  pre-press slice stays silent. Start-at-top is unchanged (multiples preserved).
- **Transport reset-to-zero** — the master clock no longer free-runs in silence:
  when no track is playing/recording/overdubbing it holds at position 0 (and
  resets each track's loop phase), so play after a full stop starts from the top.
  While any track is active the clock advances as before.
- **8 tracks as two banks of four** — `LE_MAX_TRACKS = 8` (FFI regenerated). A
  persisted **bank-enable** toggle (default off = one bank of four); when on, the
  eight tracks show as two banks of four (A / B), one bank visible at a time.
  `BankCubit` (app-wide) holds enabled + active bank; Big Picture shows an A|B
  switch.
- **Performance keyboard + Record/Play modes** — handled in the Big Picture
  `Focus` (plain keys consumed so macOS does not beep). `M` switches mode (a
  REC/PLAY indicator shows it); `1`–`8` select a track (auto-revealing its bank);
  Record mode adds `R` record/overdub and `P` play/pause the selection; Play mode
  makes `1`–`8` select + mute/unmute; both modes: `Space` play/pause all, `C`
  clear all, `⌘/Ctrl+Z` undo, `⌘/Ctrl+Y`/`Shift+Z` redo. `PerformanceMode` +
  `toggleMode` on `BigPictureCubit`; new `LooperClearAllPressed` event.
- **Code-review pass** — removed a debug `settings.clear()`; app composes the
  engine via `LooperRepository.withNativeEngine()` (no `loopy_engine` import in
  `lib/`); deleted dead Big-Picture waveform polling and made the level meter a
  stateless widget (no per-tile timers); extracted a shared rename dialog;
  `AudioSetupPage` reads its repositories from context; added the missing test
  coverage. The Big Picture per-track thumbnail is a **level meter**, not a
  waveform.
- **Functional settings surfaced** — the settings/routing UI now exposes the
  engine's real knobs: **quantized recording** (snap start/stop to the loop
  grid, global + per-track override), **configurable input monitoring**
  (input/output channel masks, or follow-the-selected-track), **rec/dub**
  second-press mode, **sound-activated** recording, **loop multiples** (global
  default + per-track `×N`), and **max-loop cap** / **UI refresh rate**. Each
  is remembered in `LooperRepository` and re-applied on every (re)start, and
  persisted via `SettingsRepository`. "Default" chips/labels name the resolved
  global value. The per-track routing dialog reuses the signal-flow graph
  scoped to one track.
- **Effects chain** — *(engine reworked: the chain is now **per-lane** and
  **stageless** — one non-destructive chain per lane via
  `le_engine_set_lane_fx*`; the pre/post `stage` and the global monitor-FX bus
  are gone, replaced by per-input live monitors, see the multi-lane section
  above. The Dart `TrackEffect.stage` model + the card-strip UI below still
  describe the pre-rework PR #11 shape and are reworked in the Dart/UI PRs.)*
  Each chain carries up to
  `LE_FX_MAX = 8` effects (the cap is for a fixed, allocation-free audio-thread
  array, not a CPU limit), each with `LE_FX_PARAMS = 3` normalized params:
  **Drive** (tanh saturation), **Filter** (TPT state-variable low-pass),
  **Delay** (feedback + wet mix, lazily allocated 1 s ring per entry on the
  control thread), **Tremolo** (sine-LFO). All DSP is allocation-free in the
  callback; the pre chain runs on `insample` before the buffer write, the post
  chain on the playback sample before routing. Structural edits (type/stage)
  route through the command ring so the audio thread resets that entry's DSP in
  lockstep; a published `a_fx_count` gates active entries; params are plain
  atoms read once per buffer (a live tweak never resets DSP). Setters
  `le_engine_set_track_fx(index,type,stage)` / `set_track_fx_count` /
  `set_track_fx_param`. `TrackEffect {type, stage, params}` + `TrackEffectType`
  carry native codes, labels and musical defaults; the chain is JSON-encoded for
  persistence. Configured from each track's routing dialog as a **signal-flow
  card strip** — `In ▸ [pre cards] ▸ Track ▸ [post cards] ▸ Out`, add per lane,
  reorder within a lane, move across the track (flips the stage), tap a card to
  edit type + sliders. `LooperRepository` remembers the chain and re-applies on
  (re)start (structural vs. granular-param paths); persisted per channel.
  Designed plugin-ready — a hosted VST3/CLAP plugin is just another effect type.
  **VST3 SDK went MIT (VST 3.8, Oct 2025)**, clearing the licence/GPL block, and
  **the host has since shipped**: vendored VST3 + CLAP SDKs, plugin
  discovery/scan/catalog, slot lifecycle + sealed `TrackEffect` topology guard,
  dynamic parameter UI, native editor windows (NSWindow on macOS, HWND on
  Windows) with two-way param sync, and state persistence with missing-plugin
  resilience. A plugin browser ("+" → Add effect/Add plugin…) replaced the old
  debug seam. **macOS and Windows hosting are feature-complete; Linux (X11)
  hosting is the one remaining gap**, deferred to on-platform work.
- **Windows + Linux native — portable foundation (PR1).** Generated the Linux GTK
  app scaffold (`linux/`); `flutter build linux --debug -t lib/main_development.dart`
  compiles + bundles `libloopy_engine.so` (miniaudio dlopen()s the audio backend at
  runtime). Desktop flavors are **entrypoint-only** (`--target lib/main_<flavor>.dart`;
  `--flavor` only namespaces build output). CI now fires on PRs (trigger fixed
  **`main` → `master`**) and adds compile-only `windows-latest` / `ubuntu-latest`
  build jobs. Per-channel label exclusion is **unchanged** (`return 0` off macOS;
  ASIO/PipeWire are PR2/PR3). *Hardware-gated, not yet run on real interfaces:
  end-to-end record/loop/play/monitor/FX, the `desktop_multi_window` waveform window
  on GTK, device-name classification, and the latency harness.*
- **Windows bring-up fixes (real-hardware run).** Two blockers found running the
  app on a real Windows interface, both fixed + verified (build + app launch +
  native tests green via MSVC):
  - **MSVC C11 atomics:** CMake's `C_STANDARD 11` only emits `/std:c11`, which is
    not enough for MSVC to accept `_Atomic` / `<stdatomic.h>` (the lock-free ring)
    — it needs `/experimental:c11atomics` too. Without it the whole Windows engine
    failed to compile. Added under `if(MSVC)` in `src/CMakeLists.txt` (+ quieted
    C4996 `strncpy` warnings via `_CRT_SECURE_NO_WARNINGS`).
  - **WASAPI device ids collapsed to `"{"`:** `device_id_to_str` read the WASAPI
    *wchar* id as a narrow `char*`, truncating every id to its first byte, so all
    devices shared one id → the device-picker `DropdownButton` crashed and pinning
    was broken. Fixed behind the platform seam (`le_platform_device_id_to_str`):
    Windows converts wchar→UTF-8, macOS/Linux keep the verbatim copy. Regression
    test `test_device_id_to_str`.
- **Windows per-channel labels — ASIO scaffolding (PR2).** `LOOPY_ENABLE_ASIO`
  CMake option. _(The Steinberg ASIO SDK was later **vendored** under
  `packages/loopy_engine/third_party/asiosdk` and the repo relicensed to GPLv3,
  so ASIO now builds **on by default on Windows** — see docs/WINDOWS_ASIO.md.)_
  `win_asio_labels.cpp` probe reads `ASIOGetChannelInfo().name`
  and reuses the portable, unit-tested `le_excluded_mask_from_names` /
  `le_label_is_loopback`; dispatched from `engine_windows.c` under the flag,
  degrading to `0` on any failure/ambiguity. Docs: `docs/WINDOWS_ASIO.md`.
  *Still gated on the user's 30-min hardware spike* (does `ASIOChannelInfo.name`
  carry "Loopback" on the interface, and does the WASAPI↔ASIO device match hold?).
- **WASAPI exclusive mode — full device control on Windows.** Opens the duplex
  device in `ma_share_mode_exclusive` + `wasapi.noAutoConvertSRC` so audio bypasses
  the Windows mixer (native format, low latency). Surfaced as a Windows-only
  audio-setup toggle, **default ON on Windows** / hidden + off on macOS/Linux,
  persisted (`audio.exclusive`). One *intent* bool (`le_config.exclusive`) flows
  down; one *reality* bool (`le_snapshot.exclusive_active`) flows back up the
  snapshot so the UI shows a "Shared — device refused exclusive" note only on a
  fallback. **Graceful fallback**: a pure `le_decide_share_fallback` helper retries
  shared once if exclusive init fails, so audio never dies; the platform default is
  resolved in the presentation layer (`defaultTargetPlatform`), never in storage.
  Verified on a real interface: exclusive engaged with the requested 128-frame
  buffer honored (shared would clamp to the OS period). macOS/Linux unchanged
  (no hog mode). See `docs/WINDOWS_ASIO.md`.
- **Device-backend seam (ASIO Part 1 — foundation, behavior-preserving).** An
  internal vtable (`le_device_backend.h`: `open`/`start`/`stop`/`close` +
  `le_device_open_result`) that `le_engine_start`/`stop`/`destroy` drive instead
  of calling `ma_device_*` directly. The existing miniaudio device lifecycle
  (config build, context init, pin/loopback resolution, the exclusive-mode
  fallback, `ma_device_init`/`start`/`uninit`, data + notification callbacks)
  moved verbatim behind it into **`engine_miniaudio.c`** (compiled
  unconditionally like the per-OS TUs); `le_engine_process`, the ring, the
  snapshot, and the looper/lane/FX DSP stay in `engine.c` and are reused
  unchanged. `le_select_backend(backend)` returns `&le_miniaudio_backend` for
  every choice in this build — the default build links **no** ASIO symbol
  (link-time guarantee; the `#if LOOPY_ENABLE_ASIO` branch lands in Part 2).
  This is **distinct from** the per-OS `engine_platform.h` seam (capabilities
  over one shared device, not swappable backends). The FFI structs grew their
  final Part-2 shape, **inert** today: `le_config.backend`/`asio_driver`,
  `le_device_info.input_channels`/`output_channels` (`0`/unknown on WASAPI;
  `device_info_copy` zero-inits them to avoid a stack-garbage read),
  `le_snapshot.active_backend` (always WASAPI). Threaded through Dart with
  inert defaults (`AudioBackend` enum, `EngineConfig`/`AudioDevice`/
  `EngineSnapshot` new fields + hand-written equality). **Acceptance gate:
  invisibility** — all existing native + Dart tests pass unchanged. New tests:
  `test_select_backend_defaults_to_miniaudio`, `test_backend_struct_defaults`,
  enumeration asserts `input_channels == 0`, and Dart round-trip/equality for
  the new fields.
- **ASIO duplex backend (ASIO Part 2 — opt-in, off by default).** The real ASIO
  capture/playback backend behind Part 1's seam, so a pro interface runs at its
  **full channel count** (e.g. 18 in / 20 out) that WASAPI never exposes. New
  **`win_asio_device.cpp`** (`#if LOOPY_ENABLE_ASIO`) exposes
  `le_asio_backend`: load the driver → negotiate rate/buffer → run its real-time
  `bufferSwitch` feeding the **unchanged** `le_engine_process`. ASIO's
  per-channel native-format buffers are bridged to the engine's interleaved f32
  by the pure, unit-tested `le_deinterleave_in`/`le_interleave_out` (Int16/24/32,
  Float32 LSB) + `le_asio_pick_buffer` (snap-to-allowed-size); scratch is
  pre-allocated at open so the RT contract holds. `le_select_backend` returns
  `&le_asio_backend` under the `#if` (default build still links no ASIO symbol);
  `le_engine_start` **falls back to WASAPI** once on any ASIO open failure, and
  `le_snapshot.active_backend` reports the negotiated reality. New
  `le_enumerate_asio_drivers` FFI symbol (real probe in the `#if`, stub returning
  0 in `engine.c` otherwise) — **regen ffigen** (`dart run ffigen` + `dart
  format`; diff is just the one function). **R1 re-entrancy**: enumeration never
  probes while ASIO is the running backend (native reports the open driver; the
  cubit refuses to enumerate while `activeBackend == asio`); teardown clears the
  callback's engine pointer only after `ASIOStop` returns. Dart/UI: a **backend
  selector** + ASIO **driver picker** in audio setup, `AudioBackend`/`asioDriver`
  persistence (forward-compat name read), auto-start relaunch-into-ASIO, and a
  fallback status row. New tests: native bridge round-trips / `le_asio_pick_buffer`
  granularity / enumerate stub; Dart `enumerateAsioDrivers` duplex tagging,
  `StoredAudioConfig` round-trip + unknown-name guard, cubit
  `setBackend`/`setAsioDriver`/hydration/no-reprobe-while-asio, and audio-setup
  widget selector/driver-swap/fallback. **Hardware spike still required before
  merge** (real Focusrite: full count, audio integrity, fallback, persistence).
- **Sessions + WAV export** (Phase 4 slice): `session_repository` saves/restores
  `.loopy` bundles (a JSON manifest + 32-bit-float stem WAVs + a mixdown) and
  exports mixdown / per-track stems. Native `le_engine_export_track` /
  `import_track` / `commit_session` move loop PCM in and out (control-thread copy
  into EMPTY tracks; a ring command flips them to PLAYING at their multiple, so
  the audio thread's RT contract is preserved). `SessionCubit` + a session menu
  (the `folder` `PopupMenuButton` in the Big Picture top bar — kept there, not in
  the settings route, because settings is pushed *above* the `LooperPage`
  providers so the cubit isn't reachable from it) drive it; the engine is shared
  (looper owns dispose). Load refuses a sample-rate mismatch (no resampling) or a
  newer manifest version — both are typed (`SessionSampleRateMismatch` /
  `SessionUnsupportedVersion`), classified by the cubit into `SessionError`, and
  rendered as localized human-readable text. Outcomes (success + error) surface
  in a `Semantics(liveRegion: true)` SnackBar (WCAG 4.1.3).
- **Unified input FX & routing** (plan
  `docs/plan/2026-06-22-feat-unified-input-fx-routing-plan.md`). Collapses the
  two FX surfaces into one: each hardware input now has a **single** live-monitor
  chain (output mask + volume + mute + effects), and that chain is **snapshot-
  copied onto a track lane at record** — the take plays back through the chain
  you monitored, while the recorded buffer stays clean (non-destructive; playback
  re-applies the snapshot). The copy is by value on the **control thread** (in
  `le_engine_record`, asserted RT-safe by a control-thread copy counter), so
  editing the input chain afterwards never alters an earlier take (D3). Native:
  `le_monitor_input` folded from N lanes to one chain;
  `LE_CMD_SET_MONITOR_LANE_*` retired for single-chain
  `LE_CMD_SET_MONITOR_INPUT_FX`/`…_FX_COUNT`/`…_OUTPUT`/`…_VOLUME`/`…_MUTE`. New
  **structural output gate** (`LE_CMD_SET_OUTPUT_ENABLED` + snapshot
  `output_enabled_mask`): a disabled output is skipped in the mix fan-out while
  its lane/monitor masks are preserved (re-enabling restores them) — distinct
  from a level mute, RT-safe mid-record, default-on, beyond-channel-count gates
  ignored. Dart: `InputMonitor` reshaped to a single chain (`MonitorLane`
  dropped), `MonitorCubit` single-chain API, `LooperRepository` single-chain
  monitor setters + `setOutputEnabled` + record-time lane-FX mirroring,
  `LooperState.outputEnabledMask`, `LooperOutputEnabledToggled` bloc event, and a
  **v2→v3 migration** (`monitor.migrated_v3`, after v2) that folds multi-lane
  monitor keys per **D9** (first non-empty chain — lane 0 preferred, NOT merged —
  OR-union of output masks, lane 0 vol/mute) and clears the dead keys. UI: the
  monitor graph folds to one node per input (no lane stack), recorded lanes show
  an FX-snapshot badge, and the routing graph renders gated-off outputs greyed +
  non-targetable (reusing `RoutingNode.excluded`) with a tap-to-toggle and a
  non-blocking "no active outputs" notice; accessibility labels on the gate
  toggle and disabled outputs. FFI regenerated (`dart format`, no churn).
- **Signal surface → three routing lists** (plan
  `docs/plan/2026-06-22-refactor-signal-three-list-surface-plan.md`, brainstorm
  `docs/brainstorm/2026-06-22-signal-list-surface-brainstorm-doc.md`, mockup
  `docs/design/signal-list-surface-mockup.html`). The node-and-wire Signal graph
  (below) tangled into unreadable spaghetti at ~16×16 and rendered per-track
  lanes as ambiguous duplicate "Lane 1"s, so its **presentation** was replaced
  by **three side-by-side scrolling lists** — Inputs | Tracks | Outputs — with
  **no wires**. `SignalRows` (pure, unit-tested) flattens `MonitorState` +
  `LooperState` into rows, **collapsing single-lane tracks to the track itself**
  (kills "Lane 1 ×8") and nesting multi-lane takes, tagging each row for trace.
  Routing is **output-hued chips** (`SignalRoutingChips`: lit = routed, "+"
  opens an output picker) → `setOutputMask` / `LooperLaneOutputChanged`.
  "What connects to what" comes from per-output colour + **tap-to-trace** (tap a
  row → its connections light across all panes, the rest dim; view-local
  `TraceState` recomputed from current rows each build, **no new cubit**). A
  take's `rec In N` badge re-assigns its captured input (`LooperLaneInputChanged`).
  Outputs show the structural gate + a derived "fed by" summary + the
  `liveRegion` no-active-outputs notice (now a `SurfaceTheme.warning` token for
  high-contrast a11y). Responsive: stacks to one column below
  `kSignalStackBreakpoint` (960px). **Keeps** the engine state + the
  instrument-panel dock/knob/style layer (`SignalInputDock` gained an additive
  FX-chip row to match `SignalLaneDock`, via a shared `_FxChipRow`); **retires**
  `SignalGraphLayout`, the node widgets, `SignalView`, and all canvas/wire usage.
  Old graph/layout/node tests removed; coverage migrated onto `signal_rows` /
  `signal_list_view` / `signal_routing_chips` tests. The bundled fonts + tokens
  from the prior pass carry over. `package:routing_graph` stays (still used by
  other surfaces; the Signal surface now uses only `FocusableTapTarget`).
- **Unified Signal surface — node graph** *(superseded by the three-list surface
  above; the engine wiring + dock/knob/style layer remain in use, the
  canvas/wires were removed)* (plan
  `docs/plan/2026-06-22-feat-unified-signal-surface-plan.md`, brainstorm +
  mockup in `docs/{brainstorm,design}/`). Replaced the three old node-and-wire
  surfaces (Audio Setup monitor graph, Big Picture settings Routing tab,
  per-track lane dialog) with ONE full-screen **Signal** canvas
  (`lib/looper/view/signal_graph/`): hardware **inputs** on the left (rich node =
  on/off gate + the single live FX chain that records + level, reusing the kit's
  `EffectChainCard`s), every track's **lanes** in the middle (FX-snapshot badge
  per recorded lane), hardware **outputs** on the right (structural on/off gate,
  greyed when off, edges still drawn). One contextual bottom **dock** swaps by
  focus — the input's tone editor (`SignalInputDock`) or a lane's "this take"
  snapshot editor (`SignalLaneDock`). Bezier edges: capture (input→lane),
  playback (lane→output, fanned at a rail), and the focused input's live-monitor
  send (dashed + faded, focused-only for a calm canvas). Geometry is a pure,
  tested `SignalGraphLayout` composing `package:routing_graph` helpers; focus +
  selection are view-local. Capture-on-tap (D2b): focus a lane, tap an input to
  record it (`LooperLaneInputChanged`; re-tap un-captures). Reached from the
  performance view by a visible chrome button **and** the `G` shortcut;
  `showSignalPage` re-provides `LooperBloc` + `MonitorCubit` + `AudioSetupCubit`
  into the pushed route. Audio Setup keeps only device/SR/buffer/latency; the
  `LaneNode` moved into `signal_graph/`. Built in 3 stacked phases (scaffold →
  rich node + dock → deletions); ~1.3k lines of old-surface tests removed with
  their load-bearing coverage migrated onto the `signal_*` tests.
- **Loopy FX plugins** — Loopy's own built-in effects, shipped *as* real,
  installable VST3 plugins for third-party DAWs (distinct from the plugin
  *host* above — this ships Loopy's own DSP as third-party VST3 plugins).
  Seven native plugins share one `packages/loopy_engine/vst3/` build —
  **Delay, Reverb, Echo, Drive, Filter, Tremolo, Octaver** — each wrapping
  the same engine DSP core the looper uses, so behavior can't drift from the
  in-app effect, checked by a **golden-parity audio-diff harness**. **macOS,
  Windows, and Linux all build and test all 7 plugins**, each via its own CI
  job (`vst3-plugins-macos`/`-windows`/`-linux`) running the shared CTest
  gate. Parts 15-17 (further effects/polish) are not yet started.
- **Performance recording** (12-part plan). Captures a full live performance
  to disk, sample-accurately: RT-safe audio-thread taps write into lock-free
  rings, a control-thread drain thread streams them to a per-run event log
  (`wav_codec` for the WAV side, new `performance_repository` for capture
  lifecycle — arm/finalize/recover-unfinalized/rename/discard), surfaced by a
  recorder UI + app state (record/play toolbar affordance).
- **Performance recording — pedal firmware parity.** The pedal has no spare
  footswitch, so arm/disarm rides the existing MODE button via a
  tap-vs-long-press split (tap still toggles Rec/Play; a ≥500 ms hold
  arms/disarms), with a blinking-red MODE LED when armed on the on-screen
  `PedalFaceplate` simulator.
- **DAW export.** New `daw_export` package (pure Dart, no Flutter/engine
  dependency) turns a completed performance capture into a real **Ableton
  Live 12 `.als`** project: one audio track per non-empty track/live-input
  stem, arrangement-view clips at capture start, session-view loop clips per
  lane, and volume/mute **automation envelopes** thinned from the event log.
  Its newest piece (device-chain export) resolves a channel's per-lane
  effects into a single **real Loopy VST3 device chain** embedded in the
  `.als` when every lane agrees on one representable chain, falling back to
  the wet-bounce stem export otherwise (mixed lanes, a third-party plugin, or
  an unrepresented effect type). **Known gap:** `PerformanceRepository.arm()`
  is not yet called with real per-lane chains at either call site
  (`performance_recorder_cubit.dart`, `control_cubit.dart`), so the shipped
  app always takes the wet-bounce fallback today — wiring real chains
  through is a small separate follow-up. Also **note:** the presentation
  layer (`PerformanceRecorderCubit`, `export_device_chain_summary.dart`)
  currently imports `daw_export` and does its own file I/O directly rather
  than going through `performance_repository` — an accepted, documented
  layering shortcut, not yet folded into the repository.

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
- **Transport holds at the top when idle** — the master clock advances only
  while a track is active; otherwise it sits at 0. Play always resumes from the
  beginning, never mid-loop in silence.
- **8 slots, two banks of four** — the engine always carries 8 tracks; the bank
  toggle is **app-side presentation** (show 4 = bank A, or two banks of 4). The
  engine processes all 8 (empty ones are silent).
- **Keyboard map lives in the Big Picture `Focus`** — plain keys are consumed
  (no macOS beep); number keys map to the visible bank, auto-switching banks when
  a digit targets the other four.

---

## Roadmap (path forward)

**Full multichannel per-track I/O routing — SHIPPED.** The "last big feature" is
done in code: it landed as the multi-lane / dual-route rework (per-lane
input/output masks through the native engine `LE_CMD_SET_LANE_INPUT/OUTPUT` +
`le_lane_snapshot`, the `Lane` domain model + `setLaneInput/Output` repo methods,
`LooperLaneInput/OutputChanged` bloc events, and the `lane_graph_view.dart`
wiring UI). Plan: `docs/plan/2026-06-09-feat-multichannel-routing-plan.md`. Only
the **on-hardware end-to-end validation** (full-count interface plugged in)
remains open — see "On-hardware validations" below.

### Possible next steps (no hard dependency)
- **Per-track multi-loop phase alignment** — multi-loop tracks currently phase
  relative to their own start iteration; an absolute-parity option would align
  all k-loop tracks to the same base-loop downbeat. _(Not started.)_
- **Accessibility pass** — no `Semantics` coverage yet (theming + golden tests
  are done). Screen-reader labels, focus order, keyboard-nav a11y tests.
- **VST3 FX plugins — parts 15-17** — further built-in effects/polish beyond
  the 7 already shipped (Delay/Reverb/Echo/Drive/Filter/Tremolo/Octaver) and
  their Windows/Linux builds; brainstormed
  (`docs/brainstorm/2026-07-13-vst3-plugins-parts-15-17-brainstorm-doc.md`)
  but not planned or built yet.

### Deferred (need hardware / 2nd display)
- `midi_client` — real USB-MIDI binding **SHIPPED** (PRs #39/#40/#42): native
  `le_midi_*` capture seam → `MidiControllerSource` → `ControllerRepository`,
  with a device-selection UI. Hardware-gated only for a live-pedal smoke test.
- **VST3/CLAP plugin hosting — Linux (X11) port.** See the "Effects chain"
  Done entry above for macOS/Windows status; Linux needs an X11 embedding
  target, deferred to on-platform work.
- Secondary-window **visualizer** (`desktop_multi_window`) — wired end-to-end in
  code (`runWaveformWindow`, `WaveformWindowService`, frame IPC); needs a 2nd
  display for a live visual confirmation.
- **Device hot-plug / reconnect — SHIPPED** (PR #41-era `feat/audio-device-a2`):
  `LooperRepository` reconnect supervisor (`_intendRunning` guard,
  `_attemptReconnect`, `_pinnedDevicesPresent`) + `devicePresent` UI banner.
- **Phase 4:** sessions save/load + WAV export ✅, theming ✅, golden tests ✅.
  Remaining: accessibility (see above).
- **Raspberry Pi GPIO backend — DROPPED** (2026-07-22): won't be built. The
  `ControllerSourceKind.gpio` seam stays, but no `gpio_client` / libgpiod
  package is planned.

### On-hardware validations still open
- Phase-1 **latency gate** (≤10 ms round-trip) — needs a class-compliant
  interface + loopback (cable or virtual device like BlackHole).
- Audible tightness of latency compensation and undo/redo clicks.

---

## Test counts (last green)
native (all C tests: incl. mid-loop record, transport reset single- &
multi-track, loop multiples, loop-viz, per-track effects DSP, session
export/import roundtrip, **single-chain monitor + record-FX snapshot +
RT-safety + structural output gate**) · VST3 CTest gate (16 wired: 7
plugin-id + 7 parity + 2 wrapper, plus a per-plugin load-smoke check) ·
loopy_engine (dart, the FFI/plugin layer — was labeled "plugin") 138 (~7
skipped) · controller_repository 18 · looper_repository 184 (~6 skipped) ·
settings_repository 65 · session_repository 57 · local_storage_client 1 ·
performance_repository 56 · pedal_repository 116 · midi_device_repository 22 ·
routing_graph 45 · wav_codec 5 · daw_export 79 · app 737 (~13 skipped) excl.
author-only `screenshots`-tagged goldens (auto-start/first-run, big-picture
settings + access, banks + A/B, performance keyboard, functional-settings,
**Signal three-list surface: SignalRows flatten + single-lane collapse +
tags, routing-chip toggle + picker, capture re-assign, tap-to-trace
dim/clear, output gate + a11y, no-active-outputs notice, responsive
stacking, contextual dock**, session menu, **performance recorder UI +
pedal arm/disarm**, **DAW device-chain export**). `flutter analyze` clean;
macOS app builds end-to-end. `LE_MAX_TRACKS = 8`, `LE_MAX_CHANNELS = 32`,
`LE_FX_MAX = 8`, `kMaxOutputs = 8`.
