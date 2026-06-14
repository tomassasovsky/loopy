---
title: "feat: native USB MIDI device selection (foot-pedal control)"
type: feat
date: 2026-06-14
---

## feat: native USB MIDI device selection (foot-pedal control) — Extensive

> Source brainstorm: [docs/brainstorm/2026-06-14-midi-usb-device-selection-brainstorm-doc.md](../brainstorm/2026-06-14-midi-usb-device-selection-brainstorm-doc.md).
> Stacks on `feat/multilane-monitoring` (the native per-OS seams + `controller_repository`
> live there, not yet on `master`). Branch: `feat/midi-device-selection`.

## Overview

Let the user pick a **USB MIDI input device** (a foot controller) so loopy can be
driven hands-free like a looper pedal: stomp to record / overdub / stop / undo on a
track. MIDI is **captured natively** on all three desktop OSes (CoreMIDI / ALSA
sequencer / WinMM) behind a new FFI seam mirroring the existing audio-device
enumeration, and raw messages are pushed to Dart via `NativeCallable.listener`. On
the Dart side a new `midi_client` package provides a `MidiControllerSource` that
implements the **existing** `ControllerSource` interface; the **existing**
`ControllerRepository` applies `ControllerMapping.defaults()` (CC 80→record/overdub,
81→stop, 82→undo, 83→clear on track 0) and the **existing** `LooperBloc` consumes the
resulting events. The looper remains fully usable with no MIDI device — MIDI is purely
additive.

**The controller pipeline already exists end-to-end** ([controller_repository.dart](../../packages/controller_repository/lib/src/controller_repository.dart),
wired in [run_loopy.dart:41](../../lib/app/run_loopy.dart) as `ControllerRepository(sources: const [])`,
consumed in [looper_bloc.dart:172](../../lib/looper/bloc/looper_bloc.dart)). The gap is:
(1) a native MIDI capture seam, (2) the `midi_client` Dart source, (3) device
selection UI + persistence + auto-reconnect/hotplug, and (4) wiring the source in.

## Problem Statement

A looper is a stomp instrument: the player needs to start/stop/overdub loops with
their feet while both hands play. Today loopy has no MIDI input at all — control is
mouse/keyboard only, which is unusable in performance. The controller-abstraction
layer (`controller_repository`) was built in anticipation of this but has **no source
feeding it**.

Two non-obvious constraints shape the design:

1. **Loop-boundary accuracy.** The latency/jitter between a footswitch press and the
   record start/stop directly shifts loop length. Native capture (reading the OS MIDI
   callback directly, carrying a native timestamp) keeps this tight and avoids the
   maturity/variance of cross-platform Flutter MIDI plugins. This is why MIDI capture
   is **native**, not a pub package.
2. **`ControllerRepository` is constructed once with a fixed source list** and exposes
   no runtime add/remove ([controller_repository.dart:17-25](../../packages/controller_repository/lib/src/controller_repository.dart)).
   Device selection, switching, deselect, and hotplug all need the source to come and
   go *after* construction. **This is the first thing the plan resolves** (see
   Architecture → "Swappable source").

## Proposed Solution

- **Native MIDI seam** (`le_midi_*`): enumerate input ports, open/close one, and push
  raw `{status, data1, data2, timestamp_us}` to a registered callback. A separate
  per-OS seam (`le_midi_backend.h` + `midi_backend_{apple,linux,windows}.c`), distinct
  from the audio `le_device_backend`, with a portable `midi.c` core holding the pure
  byte-parsing + backend selection (no OS MIDI headers in the core).
- **Native→Dart transport**: `NativeCallable.listener` (Dart ≥ 3.1; project is 3.11).
  The OS callback (on its own thread) writes into a small lock-free **MIDI SPSC ring**
  (a *new* ring — never a second producer on the existing audio command ring), and a
  drain step invokes the Dart callback. Carry a native timestamp for future
  quantization headroom.
- **`midi_client` package**: `MidiControllerSource implements ControllerSource`,
  long-lived (stable broadcast `inputs` stream) with a swappable underlying device
  (`open(id)` / `close()` / `enumerate()`), built over generated FFI bindings with a
  fake-injectable seam for tests. Normalizes raw bytes → `RawControllerInput`
  (`midiCc` / `midiNote`).
- **Selection UI + persistence**: a `MidiSetupCubit` (mirroring `AudioSetupCubit`) and
  a `MidiDevicePicker` (mirroring `AudioDevicePicker`) in the audio/I-O settings,
  persisting `midi.input_device_id` + `midi.input_device_name`, with a connect/
  disconnect status banner (mirroring the audio pinned-device lost/restored pattern)
  and a raw-input **activity indicator** for diagnosis. Auto-reconnect on launch
  (bootstrap) and on hotplug.

## Technical Approach

### Architecture

**Signal path**

```
USB MIDI foot pedal
  │  (OS MIDI callback thread)
  ▼
midi_backend_{apple,linux,windows}.c   enumerate / open / close / capture
  │  raw {status, data1, data2, ts_us}  → push to le_midi_ring (SPSC, new)
  ▼  drain → NativeCallable.listener (any thread → Dart isolate event loop)
MidiControllerSource : ControllerSource → Stream<RawControllerInput>  (+ activity)
  ▼
ControllerRepository  → ControllerMapping.defaults() (CC 80–83) → ControllerEvent
  ▼
LooperBloc → LooperRepository → le_engine_record/stop_track/undo/clear   (existing)
```

**Selection / persistence path** (parallel to audio):
`le_midi_enumerate` → `le_midi_info{id[256],name[256],is_default}` → `MidiDevice` →
`MidiDevicePicker` → `MidiSetupCubit` (persists `midi.input_device_id`/`_name`, drives
`MidiControllerSource.open/close`, raises status banners) → bootstrap auto-reconnect.

**Swappable source (the structural prerequisite).** Keep `ControllerRepository`'s
public contract unchanged (sources fixed at construction, one stable subscription).
`MidiControllerSource` is a **long-lived** source: its `inputs` is a persistent
broadcast stream; opening/closing/switching the physical device happens *inside* the
source and does not tear down the subscription. `run_loopy` constructs
`ControllerRepository(sources: [midiSource])`; `MidiSetupCubit` calls
`midiSource.open(id)` / `close()`. *Rationale:* zero change to `ControllerRepository`
(and its tests), no duplicate-subscription hazard on replug (EC-6), atomic A→B switch
(EC-9). Rejected alternative: adding `addSource/removeSource` to `ControllerRepository`
(more public surface, re-subscription bugs on hotplug).

**Per-OS seam + portable core** (mirrors `engine.c` / `engine_{linux,apple,windows}.c`
and `le_device_backend.h`):

- `packages/loopy_engine/src/le_midi_backend.h` — new vtable: `enumerate`, `open`,
  `close` (open/close idempotent, mirroring `le_device_backend` discipline).
- `packages/loopy_engine/src/midi.c` — portable core: `le_midi_select_backend()`,
  the SPSC `le_midi_ring`, the pure `le_midi_parse(status,d1,d2,*out)` classifier, and
  the FFI entry points. **No** `<CoreMIDI/…>` / `<alsa/…>` / `<mmsystem.h>` here.
- `midi_backend_apple.c` (CoreMIDI), `midi_backend_linux.c` (ALSA sequencer),
  `midi_backend_windows.c` (WinMM) — each wrapped whole in its OS guard (`#if defined(...)`
  → else a `typedef int ..._unused;`), all three listed unconditionally in CMake, like
  the `engine_*.c` TUs.
- `le_midi_internal.h` — test surface for the pure parser + injection hooks
  (`le_midi_push_for_test`), mirroring [engine_internal.h](../../packages/loopy_engine/src/engine_internal.h).

**FFI surface** (added to [loopy_engine_api.h](../../packages/loopy_engine/src/loopy_engine_api.h),
`LE_EXPORT`, ffigen-included via the existing `le_.*` filter):

```c
typedef struct le_midi_info {
  char id[256];   /* OS stable token where available; name otherwise */
  char name[256]; /* human-readable port label */
  int32_t is_default;
} le_midi_info;

typedef void (*le_midi_event_cb)(uint8_t status, uint8_t data1,
                                 uint8_t data2, uint64_t ts_us);

LE_EXPORT le_midi*  le_midi_create(void);
LE_EXPORT void      le_midi_destroy(le_midi* m);                 /* idempotent; closes if open */
LE_EXPORT int32_t   le_midi_enumerate(le_midi_info* out, int32_t max, int32_t* count);
LE_EXPORT int32_t   le_midi_open(le_midi* m, const char* id, le_midi_event_cb cb);
LE_EXPORT int32_t   le_midi_close(le_midi* m);                  /* idempotent */
```

Add `le_midi_info` to `ffigen.yaml` `structs.include`; regen bindings + `dart format`
per [ffigen.yaml](../../packages/loopy_engine/ffigen.yaml) instructions.

**Per-OS device identity** (persist `id`, match on reconnect by `id` then fall back to
`name`):

| OS | Stable id | Notes |
|----|-----------|-------|
| macOS (CoreMIDI) | `kMIDIPropertyUniqueID` (SInt32 → decimal string) | stable across replug/reboot; name from `kMIDIPropertyDisplayName` |
| Linux (ALSA seq) | client name (client:port not stable) | match by name |
| Windows (WinMM) | `szPname` (**index NOT stable**) | id == name; 31-char truncation caveat; disambiguate duplicates with an index suffix |

### Implementation Phases

Each phase is independently mergeable → **suggested 3-PR split** (run
`/plan-technical-review` to confirm).

#### Phase 1 (PR A): Native MIDI capture seam

- **Add** `le_midi_backend.h`, `midi.c`, `le_midi_internal.h`, `midi_backend_apple.c`,
  `midi_backend_linux.c`, `midi_backend_windows.c`; extend
  [loopy_engine_api.h](../../packages/loopy_engine/src/loopy_engine_api.h) with the
  `le_midi_*` surface + `le_midi_info`.
- **Portable core (`midi.c`)**: `le_midi_ring` (SPSC, fixed capacity ~128, mirroring
  [lockfree_ring.c](../../packages/loopy_engine/src/lockfree_ring.c)); pure
  `le_midi_parse` (Note On/Off w/ velocity-0 = Note Off, CC; drop SysEx/real-time/
  partial/aftertouch); atomic callback pointer (`_Atomic`, release/acquire) so close
  can null it before teardown (no use-after-free); `le_midi_select_backend()`.
- **CoreMIDI** (`midi_backend_apple.c`): `MIDIClientCreate` (main run loop) +
  `kMIDIMsgSetupChanged` notify for hotplug; `MIDIGetNumberOfSources`/`MIDIGetSource`
  + `kMIDIPropertyDisplayName`/`kMIDIPropertyUniqueID`; `MIDIInputPortCreateWithProtocol`
  (`kMIDIProtocol_1_0`, macOS 11+) + `MIDIPortConnectSource`; decode 1 UMP word →
  `(status,d1,d2)`.
- **ALSA seq** (`midi_backend_linux.c`): `snd_seq_open`; enumerate
  READ|SUBS_READ MIDI_GENERIC ports with `snd_seq_port_info_get_name`; create input
  port + `snd_seq_subscribe_port`; dedicated blocking-read thread (`snd_seq_event_input`)
  with a shutdown `poll` pipe; subscribe to System:Announce for hotplug.
- **WinMM** (`midi_backend_windows.c`): `midiInGetNumDevs`/`midiInGetDevCaps`;
  `midiInOpen(CALLBACK_FUNCTION)` + `midiInStart`; in `MidiInProc` only push to the
  SPSC ring (no allocation/syscalls — documented WinMM restriction) and `SetEvent`; a
  worker thread drains the ring → callback; hotplug via re-enumeration poll (hidden-HWND
  `WM_DEVICECHANGE` deferred).
- **CMake** ([src/CMakeLists.txt](../../packages/loopy_engine/src/CMakeLists.txt)): list
  the four new C files; `-framework CoreMIDI` on Apple (and add to
  [macos/loopy_engine.podspec](../../packages/loopy_engine/macos/loopy_engine.podspec)
  `s.frameworks`), `asound` on Linux (`find_package`), `winmm` already linked on Windows.
- **Tests** (`packages/loopy_engine/src/test/test_engine_core.c` or new
  `test_midi_core.c`): pure `le_midi_parse` cases (CC, Note On, Note-On-vel-0 → off,
  SysEx/real-time dropped, running status N/A); `le_midi_ring` wrap/full/FIFO;
  `le_midi_push_for_test` → callback delivery. Build/run with mingw gcc like the
  existing native suite.
- **Success:** native suite ALL PASSED; `flutter build {windows,linux,macos} --debug`
  compiles with the new sources/links on each platform.

#### Phase 2 (PR B): `midi_client` Dart package + source

- **New package** `packages/midi_client/` (VGV `dart_package` shape):
  `MidiClient` (enumerate + open/close over `LoopyEngineBindings`, bindings-injectable
  like [native_audio_engine.dart](../../packages/loopy_engine/lib/src/native_audio_engine.dart)),
  `MidiDevice` value class (mirror [audio_device.dart](../../packages/loopy_engine/lib/src/audio_device.dart)),
  and `MidiControllerSource implements ControllerSource` (depends on
  `controller_repository`).
- `MidiControllerSource`: persistent broadcast `inputs`; `open(id)`/`close()`/
  `enumerate()`; registers a `NativeCallable.listener`, maps `(status,d1,d2)` →
  `RawControllerInput(kind: midiCc|midiNote, id, value)`; **dispose order**:
  `le_midi_close` → `NativeCallable.close()`. A `@visibleForTesting pushForTest(...)`
  to drive the stream without hardware.
- **Minimal same-trigger debounce** (default ~30 ms) in the source so a bouncing
  footswitch can't double-toggle a record (a dropped take is the worst failure). Pure,
  configurable, unit-tested. *(In v1; the only robustness logic added.)*
- **Activity signal**: expose a raw-input tap (pre-mapping) for the UI indicator;
  drive it from Note/CC only (ignore clock/active-sensing) so a chatty device doesn't
  peg it.
- **Tests**: `MidiClient` enumerate/open/close against a `FakeLoopyEngineBindings`;
  `MidiControllerSource` byte→`RawControllerInput` mapping, debounce, dispose ordering;
  reuse the existing `FakeControllerSource` for any repository-level test.
- **Success:** `very_good test` ≥ 90% on the new package; `flutter analyze` clean.

#### Phase 3 (PR C): Selection UI, persistence, wiring, lifecycle

- **Settings** ([settings_repository.dart](../../packages/settings_repository/lib/src/settings_repository.dart)):
  add `midi.input_device_id` + `midi.input_device_name` (flat keys, like `audio.*`);
  `loadMidiDevice()` / `saveMidiDevice()`. Additive — no migration record (unlike
  monitor V1/V2).
- **`MidiSetupCubit`** (mirror [audio_setup_cubit.dart](../../lib/audio_setup/cubit/audio_setup_cubit.dart)):
  enumerate; select → `saveMidiDevice` + `midiSource.open(id)`; "None" → `close` +
  clear keys; status state machine `none|connecting|connected|error|deviceGone`;
  hotplug lost/restored banners by diffing presence per tick (mirror
  `_detectConnectivity`); **never** touches the audio engine.
- **`MidiDevicePicker`** (mirror [audio_device_picker.dart](../../lib/audio_setup/view/audio_device_picker.dart)):
  dropdown with a "None" item + absent-selection fallback; empty state ("No MIDI input
  devices found"); a `MidiActivityIndicator` (raw-input blink, semantics-labelled, not
  color-only); a visible required-CCs hint ("CC 80 record · 81 stop · 82 undo · 83
  clear"). Placed in [audio_settings_section.dart](../../lib/audio_setup/view/audio_settings_section.dart),
  **visible even in Windows `asioOnly` mode**.
- **Wiring**: in [run_loopy.dart](../../lib/app/run_loopy.dart) build the
  `MidiControllerSource`, pass `ControllerRepository(sources: [midiSource])`, and thread
  the source/cubit through [app.dart](../../lib/app/view/app.dart) via `RepositoryProvider`/
  `BlocProvider`; the waveform sub-window opens **no** MIDI (guard like the existing
  orphan-window branch). Auto-reconnect on launch from saved id in
  [audio_bootstrap.dart](../../lib/app/audio_bootstrap.dart) (or a sibling
  `midi_bootstrap`), tolerating "saved device absent".
- **Tests**: `MidiSetupCubit` (select/switch/none/absent/open-fail/hotplug lost-restored,
  and "audio engine untouched"); `MidiDevicePicker` widget (empty/one/many/duplicate
  names/absent-selection/activity/keyboard+semantics); a bloc/integration test that a
  fake MIDI input fires `LooperBloc` record.
- **Success:** all gates green; manual smoke on each OS (see Acceptance).

## Alternative Approaches Considered

- **Dart MIDI plugin (e.g. `flutter_midi_command`) instead of native.** Rejected:
  loop-boundary latency/jitter + cross-platform-plugin variance; native is consistent
  with the existing audio-device seam. (User decision.)
- **Fully-native action path (native applies the mapping → engine command ring).**
  Lowest latency, but duplicates the Dart `ControllerMapping`, bypasses the tested
  pipeline + future MIDI-learn, and would need a second producer discipline on the
  command path. Rejected in favor of native-capture/Dart-mapping. (User decision.)
- **`addSource/removeSource` on `ControllerRepository`.** Rejected for the long-lived
  swappable source (less public surface, no re-subscription hazard).
- **Broaden default mapping to also match notes.** Deferred; v1 documents the CC 80–83
  requirement (no remap UI yet).

## Acceptance Criteria

### Functional Requirements

- [ ] **Happy path:** with a pedal selected, CC80 toggles record→finalize→overdub on
      track 0; CC81 stop, CC82 undo, CC83 clear. (EC happy path)
- [ ] **No MIDI device:** looper fully usable; picker shows "No MIDI input devices
      found"; no error banner. (EC-1)
- [ ] **Persist + auto-reconnect:** selected device persists and reconnects on launch
      with no user action. (EC-2)
- [ ] **Saved device absent at launch:** id/name **retained**, non-blocking "last device
      not found" status; later replug auto-attaches. (EC-2)
- [ ] **Open failure / busy:** distinct recoverable "could not open (in use?)" error;
      id retained; success later clears it. (EC-3)
- [ ] **Unplug idle:** one-shot disconnect banner; source stops; no callback into freed
      Dart state. (EC-4)
- [ ] **Unplug mid-recording:** the active audio take continues uninterrupted; only MIDI
      status changes. (EC-5)
- [ ] **Replug:** auto re-attach; exactly one subscription; one stomp → one event (no
      duplicates). (EC-6)
- [ ] **Different device same port:** not auto-adopted; saved pin unchanged. (EC-7)
- [ ] **Duplicate names:** id-keyed selection opens the correct device; document per-OS
      id stability incl. WinMM-index caveat. (EC-8)
- [ ] **Switch A→B:** A closed, B opened, only B emits; settings reflect B; no leaked
      native handle. (EC-9)
- [ ] **"None":** closes device, stops events, clears keys; relaunch stays off. (EC-10)
- [ ] **Diagnosis:** activity indicator is driven by **raw** input (pre-mapping): an
      unmapped CC / Note On blinks it but fires no action. (EC-11/12/13)
- [ ] **Momentary semantics:** a 127→0 sequence yields exactly one action; latching
      pedals documented as unsupported. (EC-14)
- [ ] **Debounce:** sub-30 ms repeats of the same trigger collapse to one event. (EC-15)
- [ ] **FFI framing:** SysEx/real-time/partial messages never crash the listener nor
      produce spurious inputs. (EC-16)
- [ ] **Switching MIDI never restarts audio**; MIDI picker visible even in Windows
      `asioOnly` mode. (EC-17)
- [ ] **Background control:** a footswitch triggers actions while the app is unfocused/
      minimized (verified per OS). (EC-18)
- [ ] **Hot restart / sub-window:** re-attaches exactly one source; waveform window opens
      no MIDI. (EC-19)

### Non-Functional Requirements

- [ ] Real-time safety: OS MIDI callback does no alloc/lock/syscall on the hot path; no
      second producer on the audio command ring; native MIDI is independent of the audio
      engine lifecycle.
- [ ] Perceived footswitch→action latency dominated by `NativeCallable.listener`
      delivery (no polling stall); native timestamp carried for future quantization.
- [ ] Accessibility: picker keyboard-operable; status + activity exposed to screen
      readers (semantics, not color-only). (EC-22/23)
- [ ] Portable core (`midi.c`) includes no OS MIDI headers; per-OS code only in the
      guarded backend TUs.

### Quality Gates

- [ ] Native suite ALL PASSED (incl. new MIDI parser/ring tests).
- [ ] `flutter analyze` clean; `dart format` clean.
- [ ] `flutter test` green; new `midi_client` package ≥ 90% coverage.
- [ ] `flutter build windows|linux|macos --debug` all compile with the new sources/links.
- [ ] Code review approval.

## Success Metrics

- A user can plug a CC-configured foot controller, select it once, and thereafter
  control record/overdub/stop/undo/clear hands-free across app restarts and cable
  replugs, with the app unfocused — with zero looper regressions when no MIDI is present.

## Dependencies & Prerequisites

- Builds on `feat/multilane-monitoring` (`controller_repository`, per-OS engine seams).
- Dart ≥ 3.1 for `NativeCallable.listener` (project 3.11 ✓).
- Link deps: CoreMIDI (macOS, podspec), libasound2-dev (Linux CI), winmm (Windows,
  already linked). macOS 11+ for the new CoreMIDI API.

## Risk Analysis & Mitigation

- **Native→Dart callback lifetime (use-after-free).** Atomic callback pointer nulled in
  `le_midi_close` before teardown; Dart disposes native (`le_midi_close`) before
  `NativeCallable.close()`. Tested via dispose-ordering unit test + close-then-push.
- **WinMM `MidiInProc` restrictions / unstable index.** Callback only pushes to the SPSC
  ring + `SetEvent`; worker thread does the rest. Persist/match by name; disambiguate
  duplicates.
- **Three native backends = surface area.** Pure parser + ring are portable and unit-
  tested without hardware; per-OS code isolated and compile-gated; manual smoke per OS.
- **Background delivery uncertainty (EC-18).** Verify early on each OS; if a platform
  gates callbacks when unfocused, document and treat as a platform limitation.
- **Scope creep toward remap UI.** Explicitly deferred; v1 ships the fixed default
  mapping + the CC hint.

## Future Considerations

- MIDI-learn / remap UI (scaffolding already in `ControllerRepository.learnNext`/`bind`).
- `midiNote` default mappings; per-MIDI-channel filtering (trigger is channel-agnostic
  today); MIDI **output** (LED feedback to the pedal); multiple simultaneous sources;
  GPIO source (`gpio_client`) reusing the same `ControllerSource` seam; quantized
  MIDI-triggered actions using the carried native timestamp.

## Documentation Plan

- `docs/` MIDI setup note (required CCs, supported pedals, momentary-mode caveat).
- Update README feature list; CHANGELOG.
- Per-OS build/link notes (CoreMIDI framework, libasound dep) alongside
  [docs/RUNNING_ON_LINUX.md](../../docs/RUNNING_ON_LINUX.md) / WINDOWS_ASIO.md.

## References & Research

### Internal References

- Controller pipeline: [controller_repository.dart](../../packages/controller_repository/lib/src/controller_repository.dart),
  [controller_source.dart](../../packages/controller_repository/lib/src/controller_source.dart),
  [controller_mapping.dart](../../packages/controller_repository/lib/src/controller_mapping.dart),
  [controller_input.dart](../../packages/controller_repository/lib/src/controller_input.dart),
  [looper_action.dart](../../packages/controller_repository/lib/src/looper_action.dart)
- Wiring: [run_loopy.dart:41](../../lib/app/run_loopy.dart), [app.dart](../../lib/app/view/app.dart),
  [looper_bloc.dart:172](../../lib/looper/bloc/looper_bloc.dart), [looper_page.dart:31](../../lib/looper/view/looper_page.dart)
- Audio-device analog: [loopy_engine_api.h](../../packages/loopy_engine/src/loopy_engine_api.h)
  (`le_device_info`, `le_enumerate_*`, `LE_EXPORT`), [native_audio_engine.dart](../../packages/loopy_engine/lib/src/native_audio_engine.dart),
  [audio_device.dart](../../packages/loopy_engine/lib/src/audio_device.dart),
  [audio_setup_cubit.dart](../../lib/audio_setup/cubit/audio_setup_cubit.dart),
  [audio_device_picker.dart](../../lib/audio_setup/view/audio_device_picker.dart)
- Seam pattern: [le_device_backend.h](../../packages/loopy_engine/src/le_device_backend.h),
  `engine_{linux,apple,windows}.c`, [engine_internal.h](../../packages/loopy_engine/src/engine_internal.h),
  [lockfree_ring.c](../../packages/loopy_engine/src/lockfree_ring.c)
- Build/codegen: [src/CMakeLists.txt](../../packages/loopy_engine/src/CMakeLists.txt),
  [macos/loopy_engine.podspec](../../packages/loopy_engine/macos/loopy_engine.podspec),
  [ffigen.yaml](../../packages/loopy_engine/ffigen.yaml)
- Persistence: [settings_repository.dart:113-125](../../packages/settings_repository/lib/src/settings_repository.dart)

### External References

- CoreMIDI: https://developer.apple.com/documentation/coremidi/ — `MIDIInputPortCreateWithProtocol`, `MIDIEventPacket`, `kMIDIPropertyDisplayName`/`UniqueID`, `kMIDIMsgSetupChanged`
- ALSA sequencer: https://www.alsa-project.org/alsa-doc/alsa-lib/seq.html
- WinMM: https://learn.microsoft.com/windows/win32/api/mmeapi/nf-mmeapi-midiinopen , https://learn.microsoft.com/windows/win32/multimedia/mim-data , `MidiInProc` restrictions
- Dart FFI: https://api.dart.dev/dart-ffi/NativeCallable/NativeCallable.listener.html (≥ Dart 3.1)
- MIDI 1.0 message format: http://www.somascape.org/midi/tech/spec.html

### Related Work

- Brainstorm: [docs/brainstorm/2026-06-14-midi-usb-device-selection-brainstorm-doc.md](../brainstorm/2026-06-14-midi-usb-device-selection-brainstorm-doc.md)
- Prior PRs in the native/controller stack: [#27](https://github.com/tomassasovsky/loopy/pull/27) (device-backend seam), [#28](https://github.com/tomassasovsky/loopy/pull/28) (native Windows/Linux), [#29](https://github.com/tomassasovsky/loopy/pull/29) (multi-lane monitoring; `controller_repository`)
