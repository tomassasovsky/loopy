---
date: 2026-06-14
topic: midi-usb-device-selection
---

# MIDI USB Device Selection — Convert loopy into a Foot Pedal

## What We're Building

Let the user pick a **USB MIDI input device** (typically a foot controller) so loopy
can be driven hands-free like a looper pedal — stomp to record / overdub / stop /
undo on a track. The MIDI device is **enumerated, selected, and captured natively**
(per-OS backends behind the FFI boundary, mirroring the existing audio-device
pattern), and raw MIDI messages are forwarded to Dart, where the **already-existing**
`controller_repository` applies its default mapping and drives the looper.

The looper-control plumbing is already complete and wired end-to-end — `ControllerSource`
(a `Stream<RawControllerInput>`), `ControllerMapping.defaults()` (CC 80–83 →
record/overdub, stop, undo, clear on track 0), `ControllerRepository`, and a
`LooperBloc` that already subscribes to it. Today it is constructed with
`sources: const []`. **The gap is the MIDI source itself plus device selection +
persistence.** No change to the looper-action semantics is needed.

## Why This Approach

The decisive finding is that loopy already separates *controller input* from *looper
action* via `controller_repository`. That makes "MIDI device selection" a matter of
(a) producing `RawControllerInput` events from a real USB MIDI device and (b) giving
the user a way to choose which device.

**MIDI capture is native, not a Dart plugin.** For a *looper*, the latency and jitter
between a stomp and the resulting action affect loop-boundary accuracy (a record
start/stop that lands late shifts loop length and causes drift). A native capture
path — reading the OS MIDI callback directly and carrying a native timestamp — keeps
this tight and avoids depending on the maturity/variance of cross-platform Flutter
MIDI plugins. It is also consistent with how audio devices are already enumerated and
opened natively behind the FFI seam.

**Mapping stays in Dart ("native capture, Dart mapping").** Native owns enumeration +
raw capture + forwarding; Dart keeps the mapping/action logic in the existing,
already-tested `ControllerRepository`. This reuses the established controller
infrastructure (including future MIDI-learn) and keeps the action path testable in
Dart, while still getting the native capture win. The accepted cost is a
native→Dart→native hop on the *action* dispatch; mitigated by carrying a native
capture timestamp so the engine retains headroom to quantize later if needed.

**Device selection mirrors audio-device selection.** The audio path
(`le_enumerate_*_devices` → `AudioDevice` → `AudioDevicePicker` →
`AudioSetupCubit` → persisted `audio.*_device_id`) is the direct analog. MIDI gets a
parallel `le_enumerate_midi_inputs` → `MidiDevice` → picker → cubit → persisted
`midi.input_device_id`, following the same shapes for consistency.

## Key Decisions

- **v1 scope = device selection + default mapping.** Enumerate / select / persist a
  USB MIDI input device and feed it through the existing `ControllerMapping.defaults()`
  (CC 80–83 → record-overdub, stop, undo, clear on track 0). **No** remap / MIDI-learn
  / editable-bindings UI in v1. *Rationale:* smallest shippable pedal; the controller
  infra already exists, so the only new surface is the MIDI source + selection.

- **MIDI access is native.** A new per-OS MIDI input seam in the engine handles
  enumeration and raw capture, exposed across the FFI boundary. *Rationale:*
  performance/latency for loop-boundary accuracy and reliability over Flutter MIDI
  plugins; consistent with the existing native audio-device seam.

- **Native capture, Dart mapping.** Native forwards raw MIDI messages to Dart; the
  existing `ControllerRepository` maps them to `ControllerEvent`s consumed by
  `LooperBloc`. *Rationale:* reuse the complete, tested controller pipeline (and its
  future MIDI-learn) while keeping the capture native.

- **All three desktop platforms in v1.** CoreMIDI (macOS), ALSA (Linux), and a
  Windows MIDI backend, each as a per-OS seam mirroring `engine_windows.c` /
  `engine_linux.c` / `engine_apple.c`. *Rationale:* loopy targets macOS/Windows/Linux;
  ship parity rather than stubbing platforms.

- **Persist + auto-reconnect + hotplug.** Remember the chosen device, reconnect on
  launch (like the audio device, via the bootstrap path), re-attach on replug, and
  surface connect/disconnect status. *Rationale:* a pedal must "just work" across power
  cycles and cable wiggles without re-opening settings.

- **Keep CC 80–83 defaults; document the requirement.** Ship the existing default
  mapping unchanged; document that the pedal must be configured to send CC 80–83.
  *Rationale:* avoids guessing at note layouts with no remap UI; most footswitches are
  CC-configurable. (Broadening defaults / remap UI is a deliberate follow-up.)

- **Mapping single-source-of-truth stays in Dart.** `ControllerMapping.defaults()`
  remains the authority; native does not hold its own mapping table in v1.
  *Rationale:* one place to evolve toward MIDI-learn; native stays a dumb, fast pipe.

- **UI placement: alongside audio I/O settings.** A `MidiDevicePicker` (a
  `DropdownButton`-style stateless widget like `AudioDevicePicker`) plus a small
  cubit modeled on `AudioSetupCubit`, surfaced in the existing audio/I-O settings
  section. *Rationale:* discoverability next to device setup; reuse the proven
  cubit/view shape.

- **Minimal MIDI-activity indicator (small, included).** A lightweight "input
  received" blink / last-message readout in the picker so a user setting up hands-free
  can confirm the right device and that CCs arrive. *Rationale:* high usability value
  for a hands-free device at near-zero cost; not a remap UI.

## Architecture Sketch (for the plan to detail)

```
USB MIDI foot pedal
      │ (OS MIDI callback thread)
      ▼
[native per-OS MIDI seam]  ── enumerate / open / close / capture
  CoreMIDI · ALSA · Windows MIDI
      │ raw {status, data1, data2, timestamp}
      ▼  (FFI → Dart, push via NativeCallable.listener, thread-safe handoff)
[NativeMidiControllerSource : ControllerSource]  → Stream<RawControllerInput>
      ▼
[ControllerRepository]  applies ControllerMapping.defaults()  → ControllerEvent(action, channel)
      ▼
[LooperBloc] → [LooperRepository] → le_engine_record/stop/undo/clear (existing command ring)
```

Selection/persistence path (parallel to audio):
`le_enumerate_midi_inputs` → `MidiDevice(id,name,isDefault)` → `MidiDevicePicker` →
`MidiSetupCubit` (persists `midi.input_device_id`, opens the device, manages
reconnect/hotplug) → constructs/feeds the `NativeMidiControllerSource` into
`ControllerRepository`.

## Open Questions (for the planning phase)

- **Native→Dart transport mechanism.** `NativeCallable.listener` (push, lowest
  latency) vs `Dart_PostCObject`/`ReceivePort` native port vs polling a lock-free MIDI
  event ring (consistent with the engine's existing snapshot-poll model). The MIDI
  message arrives on an OS callback thread — the handoff must be thread-safe and must
  **not** reuse the audio command SPSC ring as a second producer. Decide the mechanism
  + threading/lifecycle in the plan.

- **Windows MIDI API choice.** Legacy WinMM (`midiInOpen`, universal, simple, adequate
  latency) vs WinRT / Windows MIDI Services (modern, newer, heavier). Lean WinMM for
  v1 unless the plan finds a blocker.

- **MIDI port identity for persistence.** Ports may lack stable IDs across replug on
  some OSes. Persist by a best-effort key (port name, plus any stable id the OS gives)
  and match on reconnect — mirror audio's `id[256]`/`name[256]` and tolerate "saved
  device not currently present."

- **Hotplug detection per OS.** CoreMIDI setup-change notifications, ALSA sequencer
  announce/port events, Windows device-change/`WM_DEVICECHANGE` (or polling
  enumeration). Pick per-OS mechanism (or a unified poll) in the plan.

- **FFI surface naming/shape.** e.g. `le_enumerate_midi_inputs`, `le_midi_open`,
  `le_midi_close`, callback registration — confirm naming + the `le_midi_info` struct
  to match existing conventions (`le_device_info`). Confirm this is excluded from the
  looper command set and lives in its own seam.

- **Coexistence with ASIO on Windows.** USB MIDI is a separate device class from the
  ASIO audio handle, so no hardware conflict is expected; confirm the MIDI open path is
  independent of the ASIO-exclusive audio open in the bootstrap ordering.

- **Bootstrap ordering.** Where MIDI enumeration/open sits relative to
  `tryAutoStartEngine` (audio enumerates ASIO drivers before engine start to avoid
  re-entrancy). Confirm MIDI enumeration has no equivalent process-global hazard.

- **Empty/error states.** No MIDI devices present; selected device removed; device
  open failure — define the UX (disabled picker, status text) and that the looper stays
  fully usable without MIDI.
