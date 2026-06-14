---
title: "feat: bidirectional MIDI looper pedal — loopy-owned state + firmware rewrite"
type: feat
date: 2026-06-14
---

## feat: bidirectional MIDI looper pedal — loopy-owned state + firmware rewrite — Extensive

> Source brainstorm: [docs/brainstorm/2026-06-14-looper-pedal-firmware-protocol-brainstorm-doc.md](../brainstorm/2026-06-14-looper-pedal-firmware-protocol-brainstorm-doc.md).
> **Stacks on** the native MIDI device-selection plan
> ([2026-06-14-feat-native-midi-device-selection-plan.md](./2026-06-14-feat-native-midi-device-selection-plan.md))
> — that feature provides MIDI **input**; this plan adds MIDI **output**/SysEx and the
> pedal protocol. Branch: `feat/midi-device-selection`. Firmware lives **in-repo** under
> `firmware/`.

## Overview

Make loopy the **single source of truth** for the physical Arduino looper pedal. loopy
holds all looper/pedal state, receives raw button/encoder events from the pedal, runs the
behavior state machine, and pushes a compact **SysEx state frame** back; the **rewritten**
firmware is a **pure thin client** that renders LEDs only from those frames and never keeps
looper state. This eliminates today's two-sources-of-truth drift (firmware `State[]` +
app). The pedal auto-binds via a **SysEx identity handshake**; control behavior is
**configurable in loopy** (no reflashing).

## Problem Statement

The existing firmware ([the old Arduino sketch]) owns a full `State[]` machine
(`E/R/O/P/M`), tracks selected track / mode / banks / volumes locally, persists volumes in
EEPROM, and blindly fires Mobius note numbers. The app and the pedal therefore each model
looper state and drift apart. The user wants one source of truth (loopy) and the pedal
reduced to input + display, with a **full firmware rewrite**.

Constraints discovered in research:
- **No master output gain in the engine.** Only per-track/lane volume exists
  ([loopy_engine_api.h:459](../../packages/loopy_engine/src/loopy_engine_api.h)). The
  encoder's "master volume" needs a new global post-mix gain (FFI + C). **Prerequisite for
  the encoder feature only** — the behavioral core (record/play/stop/mute/bank) does not
  depend on it, so it does not block the rest of the build.
- **The record command is a cycling toggle, not discrete primitives.** `le_engine_record`
  ([loopy_engine_api.h:86,453](../../packages/loopy_engine/src/loopy_engine_api.h)) is one
  command: idle→record→finalize→overdub; the repository exposes only
  `record/stopTrack/play/clear/undo/redo`. The pedal's behaviors ("finish this loop **and**
  start recording another," "finish recording **then** mute," "Rec→Play **finalizes**")
  must be **derived** by the cubit from the cycling command + the snapshot — see *Deriving
  discrete actions* below.
- **`rec_dub` already exists.** The Record→Play vs Record→Overdub choice is already a
  persisted setting (`looper.rec_dub`,
  [settings_repository.dart:251](../../packages/settings_repository/lib/src/settings_repository.dart)).
  The pedal **reuses it** — adding a parallel `pedal.rec_cycle` would recreate the exact
  two-sources-of-truth drift this feature exists to remove.
- **FastLED blocks interrupts** (~30 µs/LED ⇒ ~570 µs for 19 LEDs) at 31250 baud, which can
  **drop inbound serial MIDI**. The firmware must poll MIDI around `FastLED.show()` and
  frames must be **checksum-guarded** with a **periodic refresh** so a dropped frame
  self-heals.
- **UNO MIDI-USB** path = **reflashed ATmega16U2 (dualMocoLUFA)** + sketch `Serial` at
  31250 (not the MIDIUSB lib, which is 32U4-only).

## Proposed Solution

A dedicated, bidirectional **pedal module** in loopy (VGV layered), reusing the native MIDI
transport and adding output:

- **Engine:** a global **master output gain** (FFI `le_engine_set_master_gain` + snapshot
  field) and the **removal of the bank-enable setting** (banking always on, 2 banks of 4).
- **Native MIDI output seam:** `le_midi_out_*` (send + SysEx) on CoreMIDI / ALSA seq /
  WinMM, mirroring the input seam's open/close discipline.
- **`packages/pedal_repository/`** (data layer): the **protocol** — identity handshake,
  decode inbound Notes/CC → `PedalEvent`, encode loopy state → versioned, checksummed,
  7-bit-packed **SysEx state frame** + a **loop-top pulse**; a `PedalTransport` seam
  (FFI-free for tests) and `NativePedalTransport`.
- **`lib/pedal/` feature:** `PedalCubit` — the mode/armed-track/bank state machine + the
  **reused `looper.rec_dub`** record-cycle setting + tap/long-press/double-tap timing;
  subscribes to `LooperRepository.looperState`, **projects → frame (diffed, on-change +
  periodic refresh)**, maps events → `LooperRepository` commands and the encoder → master
  gain (encoder path only, gated on the Phase-0 master gain).
- **Settings:** clear fade, quantize-to-loop-top, long-press/double-tap timing, MIDI
  channel. (Record-cycle reuses the existing `looper.rec_dub`.)
- **`firmware/`:** full Arduino rewrite — thin client (SysEx render, Notes/CC out, identity
  reply, ring interpolation, MIDI-poll-around-show), plus 16U2 flashing docs.

## Technical Approach

### Architecture

```
Pedal (UNO + 16U2 dualMocoLUFA, FastLED ring)
  │  Notes (NoteOn=press / NoteOff=release) + relative CC (encoder)
  ▼
[native MIDI IN seam — from the device-selection plan]
  ▼ NativeCallable.listener
PedalRepository.events (decode → PedalEvent)
  ▼
PedalCubit  (mode SM · armed track (default Tr1) · bank A/B · rec-cycle setting ·
             tap/long/double timing) → LooperRepository commands
  │   subscribes LooperRepository.looperState → project → PedalStateFrame (diff)
  ▼ pushState(frame)  +  loop-top pulse
PedalRepository.encode → SysEx (7-bit, versioned, checksummed)
  ▼
[native MIDI OUT seam — NEW: le_midi_out_send]
  ▼  SysEx state frame (on change + periodic refresh) · loop-top pulse (realtime)
Pedal renders LEDs from the last good frame; ring interpolates between loop-top pulses
```

**Layering (VGV):** FFI is sealed in the data layer — `NativePedalTransport` is the only
class touching `LoopyEngineBindings`; `PedalRepository` exposes a `PedalTransport` seam; the
`PedalCubit` only sees `PedalRepository` + `LooperRepository` + `SettingsRepository`. The
generic `controller_repository` path is untouched.

**Proposed file layout:**

```
packages/pedal_repository/lib/
  pedal_repository.dart                  # barrel
  src/
    pedal_button.dart                    # enum: recPlay,stop,undo,mode,track1..4,clear,bank
    pedal_event.dart                     # sealed: ButtonPressed/Released(button,ts), EncoderDelta(d)
    pedal_state_frame.dart               # value class + PedalTrackLed{off,green,red} + GlobalColor; .blank()
    pedal_codec.dart                     # encode(frame)->Uint8List, decode(status,d1,d2)->PedalEvent?, 7-bit pack + checksum
    pedal_transport.dart                 # abstract interface class PedalTransport
    native_pedal_transport.dart          # NativePedalTransport : PedalTransport (FFI)
    pedal_repository.dart                # handshake/auto-detect, events stream, pushState, sendLoopTop
  test/ (+ test/helpers/fake_pedal_transport.dart, golden SysEx fixtures)

lib/pedal/
  cubit/pedal_cubit.dart                 # PedalCubit : Cubit<PedalState> (+ pedal_state.dart part)
  view/pedal_settings_section.dart       # status + settings (placed in audio I/O settings)
  pedal.dart                             # barrel

firmware/                                # Arduino UNO sketch (thin client) + 16U2 flashing docs
```

### SysEx protocol (versioned, checksummed, 7-bit)

- **Manufacturer id `0x7D`** (non-commercial). **MIDI channel** configurable (default 1).
- **Identity handshake:** loopy broadcasts the Universal Identity Request `F0 7E 7F 06 01
  F7`; the pedal replies `F0 7E <id> 06 02 7D <fam_lo> <fam_hi> <member×2> <rev×4> F7` with a
  fixed family signature loopy recognizes; loopy auto-binds (deterministic tiebreak:
  persisted id, else first valid reply). A protocol **version** byte is carried for forward
  compatibility but does **not** gate streaming in v1 (firmware is co-released in-repo): on a
  version mismatch loopy logs/toasts a warning and still streams. (The refuse-and-prompt flow
  is deferred to if/when firmware ships separately.)
- **State frame (loopy→pedal):** `F0 7D <ver> <type=STATE> <payload(7-bit packed)> <checksum>
  F7`. Payload: global color/state · per-track LED for **all 8 tracks** (so bank switch
  renders with no round-trip) · active bank · armed track · mode · loop length (µs) ·
  clear/fade-active flag · `isGoodbye` (set only on the shutdown blank frame — see *Goodbye*).
  Pushed **on change** (diffed) **+ a low-rate periodic refresh** so a dropped frame
  self-heals despite the FastLED gap. Refresh = **~1 Hz** (worst case ≈ 1 s of stale LEDs
  after a dropped frame; negligible MIDI bandwidth — one ~16-byte frame/s); revisit only if
  smoke testing shows visible staleness.
- **Loop-top pulse:** a **single-byte realtime message** (`Start 0xFA` at each loop top) —
  survives the FastLED interrupt gap far better than multi-byte SysEx; the pedal interpolates
  the ring spin locally from loop length between pulses (1 revolution = 1 loop).
- **Goodbye:** loopy sends a `.blank()` frame (`isGoodbye=1`, all LEDs off) on shutdown so
  the pedal darkens (USB may stay powered after the app quits).
- **Events (pedal→loopy):** one fixed **Note per button** (NoteOn=press, NoteOff=release);
  **relative CC** for the encoder. loopy times tap/long-press/double-tap.

### Behavior state machine (loopy)

**Arming:** exactly one track is **armed** at a time (default **Track 1** on a clean/reset
pedal). Recording only ever starts on the armed track, and only via **Rec/Play** (or the
track-to-track hand-off below). When nothing is recording, pressing a track button just
**re-arms** to it (no transport change). The armed track is also Undo's target.

| Control | Rec mode | Play mode |
|---------|----------|-----------|
| Track 1–4 | **While a track is recording:** same track → finish loop → play/overdub (per setting); a **different** track → finish the recording track's loop **and start recording the pressed track** (now armed). **While nothing is recording:** **arm** the pressed track (no transport change). | toggle mute (instant) |
| Rec/Play | act on the **armed** track: **empty/idle** → start recording; **recording** → finish loop → play or overdub (per `rec_dub`); **has a loop, playing/stopped/muted** → overdub it (or, if `rec_dub`=play, just (re)play it) | toggle the **remembered playing-set** (mute all playing → unmute only those) |
| Stop | **mute the armed track**; if it is recording/overdubbing, **finish the recording first** (loop kept) then mute | **mute all currently-playing tracks** |
| Undo | tap = undo armed; **long-press = redo** | same |
| Mode | toggle Rec/Play. **On Rec → Play: finalize any recording/overdubbing track (stop recording, play).** Play → Rec has no transport effect. | same |
| Clear | **clear ALL** with a configurable fade; the fade is the **guard** — a 2nd Clear or Undo during the fade aborts and retains buffers; Clear LED lit during the fade | same |
| Bank | toggle A/B (LED on for B) | same |
| Encoder | turn = master output gain; push = unused | same |

**Record-cycle setting = the existing `looper.rec_dub`** — controls only what a track does
when its **first recording finishes**: go to **Play** (`rec_dub`=off) or **Overdub**
(`rec_dub`=on). No new pedal setting.

#### Deriving discrete actions from the cycling record command

The engine's `le_engine_record` is a single cycling toggle (idle→record→finalize→overdub)
and there is **no** separate "finalize-without-overdub" or "start-on-a-specific-track"
primitive. `PedalCubit` therefore computes the command sequence from the **last snapshot's
per-track `le_track_state`** before each action. The pedal never issues a bare "record"
hoping the engine is in the right phase — it inspects state first. Concretely:

| Intended pedal action | Derivation from snapshot + commands |
|---|---|
| Start recording the armed track (it is EMPTY) | `record(armed)` once (EMPTY→RECORDING) |
| Finish loop → **play** (`rec_dub`=off) | `record(armed)` (RECORDING→finalize→PLAYING via the engine's own finalize) |
| Finish loop → **overdub** (`rec_dub`=on) | `record(armed)` to finalize, then `record(armed)` again only if the engine lands in PLAYING (engine `rec_dub` already encodes this — prefer setting the engine's `rec_dub` so a single `record` finalizes into the desired end-state rather than the pedal double-issuing) |
| Track-to-track hand-off (Tr A recording, press Tr B) | finalize A: if `state[A]==RECORDING/OVERDUBBING` → `record(A)` (or `stopTrack(A)` then `play(A)`) to land A in PLAYING; then `record(B)` to start B |
| Stop = mute armed (finalize first if recording) | if `state[armed]∈{RECORDING,OVERDUBBING}` → finalize to PLAYING first, then `setMute(armed, true)` |
| Mode Rec→Play finalize | for every track with `state∈{RECORDING,OVERDUBBING}` → finalize to PLAYING |

**Note for the build:** prefer driving the engine's existing `rec_dub` end-state +
`setMute` over re-deriving multi-step sequences where possible; if the engine cannot
finalize-without-overdub in one command for the hand-off/Stop cases, a small engine
addition (an explicit `finalize`/`stop-to-playing`) is the fallback — flag during PR4 build
if the snapshot-driven derivation proves racy. *(This is the plan's top implementation
risk; see Risks.)*

**Decided defaults for flagged items** (see Open Questions to confirm):
- **Armed track after bank switch:** per-active-bank — re-resolve to the last-armed track
  within the new bank (default Track 1 of that bank if none armed yet). Never undefined.
- **Playing-set memory:** persists until a track's recorded content changes; not invalidated
  by mute toggles or bank switches.
- **Pedal mode on bind:** reset to Rec / armed = Track 1 / bank A (no cross-launch persistence
  in v1).
- **Lost NoteOff:** a NoteOn for a button with no intervening NoteOff synthesizes a release /
  resets the hold timer (no stuck press); long-press detection is capped.

### Implementation Phases (one umbrella plan; each `####` = one PR, built/merged in order)

> Dependency summary: PR0 and PR1 are independent of everything (and each other). PR2
> stacks on the device-selection plan being merged. PR3a is pure Dart (no deps). PR3b needs
> PR2 + PR3a + the device-selection **input** seam. PR4 needs PR0 (encoder only), PR1, and
> PR3b. PR5 needs PR3a's golden fixtures only.

#### PR0: Engine master output gain
- New global post-mix gain — `LE_CMD_SET_MASTER_GAIN`, `le_engine_set_master_gain(engine,
  float)`, a `master_gain` snapshot field, applied in the final mix in
  [engine.c](../../packages/loopy_engine/src/engine.c); ffigen regen; Dart
  `LooperRepository.setMasterGain` (re-applied on engine restart like other desired-state).
  Native test for the gain math.
- **Independent;** only the PR4 encoder path depends on it (not the behavioral core).

#### PR1: Remove the bank-enable setting (banking always on)
- Drop the whole `enabled` axis from [bank_state.dart](../../lib/looper/cubit/bank_state.dart):
  `enabled`, `copyWith(enabled:)`, and simplify `bankCount`→2, `baseChannel`→`activeBank*4`,
  `contains` (no longer branch on `enabled`).
- Drop `setEnabled`/`_restore`/the `enabled` load from
  [bank_cubit.dart](../../lib/looper/cubit/bank_cubit.dart); `selectBank` no longer early-returns.
- Drop `_bankEnabledKey`/`loadBankEnabled`/`saveBankEnabled` and **stop writing**
  `big_picture.bank_enabled` ([settings_repository.dart:209](../../packages/settings_repository/lib/src/settings_repository.dart));
  the stale key is left orphaned (ignored on read), consistent with the repo's additive-key
  precedent — no migration record.
- Remove `if (bank.enabled)` gates in `big_picture_view.dart` and the bank-toggle switch in
  `big_picture_settings_page.dart`; update affected cubit/widget tests.
- **Independent** (no MIDI/engine deps); land before or after PR0.

#### PR2: Native MIDI output seam
- Extend the MIDI seam with **output**: `le_midi_out_create/destroy/open/close/send`
  (idempotent close, mirroring the input seam) in `midi_backend_{apple,linux,windows}.c` +
  `le_midi_api.h`. CoreMIDI `MIDIOutputPortCreate` + `MIDISendSysex`/`MIDISend`; ALSA
  `snd_seq_create_simple_port`(READ) + `snd_seq_connect_to` + `snd_seq_ev_set_sysex` +
  `snd_seq_event_output`/`drain`; WinMM `midiOutOpen` + `midiOutShortMsg` +
  `midiOutPrepareHeader`/`midiOutLongMsg`/wait-`MOM_DONE`/`Unprepare` (64 KB cap, buffer
  outlives the call). ffigen regen. Three symmetric ~80-LOC backends sharing the input seam's
  vtable shape → one PR (splitting by OS would just collide on the shared header/CMake).
- **Depends on** the device-selection plan being merged (it stacks on that input seam).

#### PR3a: `pedal_repository` models + codec (pure Dart, no FFI)
- `PedalButton`/`PedalEvent`/`PedalStateFrame` (+ `.blank()` / `isGoodbye`) and **`pedal_codec`**:
  encode frame → SysEx (7-bit pack, version byte, checksum), decode Note/CC → `PedalEvent`.
- **Golden SysEx fixtures** committed here as the shared contract for PR5's firmware tests.
- No deps — lands early so the firmware author has fixtures to test against.
- Tests: codec round-trip + golden bytes; decode of every button Note + relative CC;
  malformed/partial-frame rejection.

#### PR3b: `pedal_repository` transport + repository (FFI)
- `PedalTransport` seam + `NativePedalTransport` (the **only** FFI-touching class — annotated
  `// coverage:ignore-file` so the package still meets ≥90%, since it can't be exercised
  without hardware); `PedalRepository`: identity handshake + auto-bind (status:
  none/connecting/bound/unsupported-version[warn-only]/error/manual-override), `events`
  stream, `pushState`, `sendLoopTop`, idempotent dispose; reconnect supervision mirroring
  `LooperRepository._superviseDevice`.
- **Transport-seam ownership:** there is **one** native MIDI input capture per device. The
  pedal does **not** create a second `NativeCallable`/capture on the bound device — it
  **reuses** the device-selection feature's single inbound capture (the bytes are routed to
  `PedalRepository`'s decoder), so the "exactly one subscription / no double events"
  guarantee holds. `NativePedalTransport` owns only the **output** (`le_midi_out_*`). Make
  this routing explicit in the build.
- **Depends on** PR2 (output FFI) + PR3a (codec) + the device-selection input seam.
- Tests: handshake states with a `FakePedalTransport`; dropped/garbled frame discarded;
  pushState emits encoded golden bytes.

#### PR4: `lib/pedal` feature + settings + UI + wiring
- `PedalCubit`: the behavior table + *Deriving discrete actions* logic; subscribe
  `LooperRepository.looperState`; pure `projectFrame(looperState, pedalState)`; **diff before
  `pushState`** (don't emit on every playhead tick); detect loop-top (position wrap) →
  `sendLoopTop`; tap/long/double timers from settings; encoder → `setMasterGain` (gated on
  PR0); goodbye frame in `close()`.
- **Settings** ([settings_repository.dart](../../packages/settings_repository/lib/src/settings_repository.dart)):
  `pedal.clear_fade_ms` (**single key; 0 = disabled**), `pedal.quantize_to_loop_top`,
  `pedal.long_press_ms`, `pedal.double_tap_ms`, `pedal.midi_channel` (flat keys + load/save).
  **Record-cycle reuses `looper.rec_dub` — no new key.**
- **UI**: `pedal_settings_section` (bind status w/ semantics, raw-input activity indicator,
  the settings; reachable in the audio I/O settings, visible in Windows `asioOnly` mode).
  **l10n:** every new string gets `en` + `es` ARB entries in
  [lib/l10n/arb/](../../lib/l10n/arb/) (bind-status labels, "update firmware" warning,
  setting labels) — a hard project gate.
- **Wiring**: construct `PedalRepository` + `PedalCubit` in
  [run_loopy.dart](../../lib/app/run_loopy.dart), provide via `RepositoryProvider`/
  `BlocProvider`; waveform sub-window opens no pedal; auto-bind on launch.
- **Depends on** PR0 (encoder), PR1 (so `selectBank` has no dead `enabled` guard), PR3b.
- Tests: `bloc_test` for the full behavior table (flat parameterised list, not nested),
  the *derivation* sequences, projection, diff-coalescing, timing windows, stuck-press
  recovery, goodbye frame, "MIDI ops never restart audio".

#### PR5: Firmware rewrite (`firmware/`)
- Full Arduino UNO sketch, thin client: `Serial` MIDI in/out @ 31250 (dualMocoLUFA on the
  16U2); SysEx parser (validate `F0`/id/version/length/checksum/`F7`, **discard partials**,
  tolerate interleaved realtime), render 19 LEDs (FastLED) from the last good frame; ring
  interpolation from loop length + `Start 0xFA` pulse; **poll MIDI immediately before every
  `FastLED.show()`** (and chunk if needed) to avoid dropped bytes; send Notes (press/release)
  + relative CC; reply to the identity handshake; contact debounce (~10 ms); startup
  animation on loopy's hello frame.
- **Contract-test harness:** factor the SysEx parser/encoder into a plain C/C++ TU the
  sketch `#include`s, and a **host-compiled** unit test that links that TU and asserts
  against PR3a's **golden fixtures** — runs in CI like the existing mingw native suite
  (no board needed). On-device behavior is covered by the manual per-OS smoke pass.
- **Depends on** PR3a (golden fixtures) only — no Dart build coupling.
- Docs: `firmware/README.md` — dualMocoLUFA flashing (`dfu-programmer atmega16u2 …`),
  jumper/upload workflow, pin map, LED order.

## Alternative Approaches Considered

- **Keep firmware state machine / incremental patch** — rejected (the whole point is single
  source of truth + full rewrite).
- **Fold the pedal into `controller_repository`** — rejected; bidirectional + stateful +
  handshake overloads the one-way stateless `ControllerSource`. Dedicated module is the VGV
  fit.
- **Continuous position frames for the ring** — rejected for the **loop length + realtime
  loop-top pulse** (far less traffic; survives the FastLED gap).
- **MIDIUSB library** — N/A on the UNO (32U4-only); use dualMocoLUFA + serial.

## Acceptance Criteria

### Functional (must-have, from flow analysis)
- [ ] **Auto-detect handshake:** valid signature → bound + hello/startup frame, then state;
      no reply → stays unbound, generic controller path intact, manual override offered;
      version mismatch → **warn (toast/log) but still stream** (no refuse in v1); multiple
      replies → exactly one deterministic bind. (A1–A5)
- [ ] **Arming:** default armed = Track 1 on a clean pedal; pressing a track button while
      nothing records re-arms (no transport change); only one track armed at a time. (B5)
- [ ] **Rec/Play (Rec)** on the armed track: idle → starts recording; recording → finishes
      loop → play **or** overdub per the rec-cycle setting. (B1, B2)
- [ ] **Track-to-track hand-off:** while a track records, pressing a *different* track finishes
      that loop and immediately starts recording the pressed track (now armed). (B1)
- [ ] **Rec/Play (Play)** = remembered playing-set toggle (mute all playing → unmute only
      those). (C2)
- [ ] **Stop (Rec)** = mute the armed track, finishing the recording first if it was
      recording/overdubbing (loop kept). **Stop (Play)** = mute all currently-playing tracks. (B3, C3)
- [ ] **Undo** tap = undo armed; **long-press = redo**; boundary asserted at threshold ±1 ms.
      (B4, H1)
- [ ] **Play-mode** track press = instant mute toggle. (C1)
- [ ] **Bank** toggle flips active bank; pushed frame already carries all 8 tracks; an
      off-bank recording continues uninterrupted on switch. (D1, D3)
- [ ] **Armed track after bank switch** is always defined (per-active-bank rule). (D2)
- [ ] **Encoder** turn changes the engine master gain (which now exists) and persists. (E1)
- [ ] **Clear** = clear-all guarded by the fade window (2nd Clear/Undo aborts, buffers
      retained); Clear LED lit for the fade. (I1)
- [ ] **Mode switch Rec → Play** finalizes any recording/overdubbing track (stops recording,
      plays); Play → Rec has no transport effect. (H6)
- [ ] **Ring** = 1 revolution per loop via loop-top realtime pulse; idle pattern when no loop.
      (F1, F2)
- [ ] **Lifecycle:** goodbye frame on shutdown; replug re-binds with exactly one
      subscription/binding (no double events); replug mid-record leaves the take intact;
      stale display after a crash is harmless (pedal never self-acts). (G1–G4, G5 stuck-press)
- [ ] **Robustness:** garbled/partial SysEx is discarded (last good frame retained, no crash);
      dropped frame self-heals via the periodic refresh; all SysEx payload bytes are 7-bit;
      interleaved realtime doesn't corrupt parsing. (H3, H4)
- [ ] **Debounce:** one physical stomp = one logical event (never a double record toggle).
      (H2)

### Non-Functional
- [ ] FFI sealed in the data layer; `controller_repository` untouched; portable engine core
      free of OS MIDI headers.
- [ ] No alloc/lock on the OS MIDI callback; output handle lifecycle idempotent; MIDI never
      restarts the audio engine.
- [ ] Firmware never drops inbound MIDI due to `FastLED.show()` (poll-around-show verified).
- [ ] Pedal settings/status keyboard-operable + screen-reader-labelled (not color-only),
      visible in Windows `asioOnly` mode.
- [ ] Every new pedal UI string has `en` + `es` ARB entries (l10n gate); record-cycle reuses
      `looper.rec_dub` (no duplicate setting); the FFI transport class is `coverage:ignore`
      so the package still meets ≥90%.

### Quality Gates
- [ ] Native suite ALL PASSED (master-gain + any MIDI-out unit bits).
- [ ] `flutter analyze` clean; `dart format` clean; new packages ≥ 90% coverage.
- [ ] `flutter test` green; codec golden fixtures pass on both loopy and firmware sides.
- [ ] `flutter build windows|linux|macos --debug` compile; firmware compiles (arduino-cli).
- [ ] Manual per-OS smoke: plug pedal → auto-bind → record/overdub/play/stop/undo/clear,
      bank, mute, master volume, ring sync, replug.

## Success Metrics

A performer plugs the pedal, it auto-binds, and every footswitch/encoder action drives loopy
hands-free with LEDs that always reflect loopy's true state — with zero firmware-side state
and zero looper regressions when no pedal is present.

## Dependencies & Prerequisites

- Stacks on the native MIDI **input** device-selection feature (same branch) — reuses its
  enumeration/open/capture (incl. the single inbound capture the pedal reuses) + adds output.
- Engine **master output gain** (PR0) is a prerequisite **for the encoder path only**, not
  for the behavioral core.
- 16U2 reflashed to dualMocoLUFA; FastLED; arduino-cli/PlatformIO toolchain for `firmware/`.

## Risk Analysis & Mitigation

- **(Top risk) Deriving discrete actions from the cycling `record` command.** The
  hand-off / Stop-finalize / Rec→Play-finalize behaviors assume a "finalize-without-overdub"
  the engine may not expose in one command. Mitigation: snapshot-driven derivation (see
  *Deriving discrete actions*); if it proves racy in PR4, add an explicit engine
  `finalize`/`stop-to-playing` command (small, isolated) as the fallback.
- **FastLED interrupt gap drops MIDI** → poll-around-`show()` + chunking + checksum + periodic
  refresh; realtime loop-top pulse. (If unreliable, document APA102/Teensy as the hardware
  fix — out of scope.)
- **Data loss from Clear-all** → the fade window is the guard (abortable); buffers retained
  until the fade completes.
- **Handshake false-positives / two pedals** → strict signature match; deterministic single
  bind; manual override. (Version is warn-only in v1, not a gate.)
- **Protocol drift loopy↔firmware** → shared golden SysEx fixtures both sides test against.

## Future Considerations

Mode LED; active heartbeat liveness; cross-launch pedal-mode persistence; two-pedal mirroring;
quantize-to-loop-top action snapping; pedal-button remap/MIDI-learn; encoder-push function;
richer clear-effect curves; MIDI **output** LED feedback variants.

## Documentation Plan

`firmware/README.md` (flashing + pin/LED map + protocol); a `docs/` loopy↔pedal **protocol
spec** (frame layout, identity handshake, 7-bit packing, checksum, version) as the shared
contract; README feature entry; CHANGELOG.

## References & Research

### Internal
- Engine surface: [loopy_engine_api.h](../../packages/loopy_engine/src/loopy_engine_api.h)
  (`le_track_state`, `le_snapshot`, per-track volume @459, command codes), `engine.c`
- Looper commands/state: [looper_repository.dart](../../packages/looper_repository/lib/src/looper_repository.dart)
  (record/stopTrack/play/clear/undo/redo/setVolume/setMute @429-456; `_project`/`_poll`/`_superviseDevice`)
- Banks: [bank_cubit.dart](../../lib/looper/cubit/bank_cubit.dart) / bank_state.dart
- Controller pipeline (untouched): [controller_repository.dart](../../packages/controller_repository/lib/src/controller_repository.dart)
- Wiring: [run_loopy.dart](../../lib/app/run_loopy.dart), [app.dart](../../lib/app/view/app.dart),
  [looper_bloc.dart](../../lib/looper/bloc/looper_bloc.dart)
- Settings: [settings_repository.dart](../../packages/settings_repository/lib/src/settings_repository.dart)
- Dependency plan: [native MIDI device selection](./2026-06-14-feat-native-midi-device-selection-plan.md)
- The old firmware sketch (behavior reference; to be fully replaced).

### External
- CoreMIDI out/SysEx: `MIDIOutputPortCreate`, `MIDISend`/`MIDISendSysex` — https://developer.apple.com/documentation/coremidi/
- ALSA seq out/SysEx: `snd_seq_event_output`, `snd_seq_ev_set_sysex` — https://www.alsa-project.org/alsa-doc/alsa-lib/seq.html
- WinMM out/SysEx: `midiOutLongMsg`/`midiOutPrepareHeader` — https://learn.microsoft.com/windows/win32/api/mmeapi/nf-mmeapi-midioutlongmsg
- MIDI Identity Request/Reply + non-commercial id `0x7D` — http://midi.teragonaudio.com/tech/midispec/identity.htm
- SysEx 7-bit packing — https://www.echevarria.io/blog/midi-sysex/index.html
- UNO USB-MIDI (dualMocoLUFA) — https://github.com/kuwatay/mocolufa
- FastLED interrupts vs MIDI — https://github.com/FastLED/FastLED/wiki/Interrupt-problems

### Related Work
- Brainstorm: [looper-pedal-firmware-protocol](../brainstorm/2026-06-14-looper-pedal-firmware-protocol-brainstorm-doc.md)
- Stacked feature: [native USB MIDI device selection](./2026-06-14-feat-native-midi-device-selection-plan.md)
- Prior native/controller PRs: [#27](https://github.com/tomassasovsky/loopy/pull/27), [#28](https://github.com/tomassasovsky/loopy/pull/28), [#29](https://github.com/tomassasovsky/loopy/pull/29)

## Open Questions (confirm before / during build)

**Still open (confirm before / during build):**

1. **Master gain semantics** — confirm a new global post-mix gain (vs scaling per-track) and
   its range/step. *(Encoder path only — does not block other PRs.)*
2. **Clear-all guard** — confirm fade-as-abort-window (vs hold-to-confirm / double-press).
3. **Armed-track-after-bank-switch** — confirm per-active-bank re-resolution (default Track 1
   of the new bank).
4. **Loop-top pulse** — confirm realtime `Start 0xFA` (vs custom SysEx).
5. **Playing-set memory** invalidation rule (default: persists until a track's recorded
   content changes).
6. **Pedal-mode persistence** across launches (default: reset on bind — Rec / armed Track 1 /
   bank A).
7. **MIDI channel** default + whether per-pedal configurable.
8. **Cycling-command derivation fallback** — confirm we may add a small engine
   `finalize`/`stop-to-playing` command if snapshot-driven derivation proves racy in PR4.

**Resolved in this revision:**

- ~~Mode-switch-mid-record~~ — Rec → Play finalizes any recording/overdubbing track (play);
  Play → Rec has no transport effect.
- ~~Stop-in-Rec~~ — Stop **mutes** the armed track (finalizing a recording first); the engine
  STOPPED state is unused by the pedal (mute drives the LED off).
- ~~Record-cycle setting~~ — reuse the existing `looper.rec_dub` (no new `pedal.rec_cycle`).
- ~~Dropped-frame recovery~~ — checksum + ~1 Hz periodic refresh.
- ~~Protocol version gating~~ — carried for forward-compat but **warn-only** in v1 (firmware
  co-released in-repo).
- ~~Master-gain blocking scope~~ — prerequisite for the **encoder only**, not the core.
- ~~clear-fade keys~~ — single `pedal.clear_fade_ms` (0 = disabled).
