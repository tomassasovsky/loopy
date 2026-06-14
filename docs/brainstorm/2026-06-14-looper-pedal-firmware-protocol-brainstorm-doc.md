---
date: 2026-06-14
topic: looper-pedal-firmware-protocol
---

# Looper Foot Pedal — Behavior & loopy↔Pedal Protocol

## What We're Building

A full redefinition of the physical Arduino-based looper foot pedal so that **loopy is
the single source of truth** for all looper state. The pedal becomes a **pure thin
client**: it sends raw button/encoder events to loopy and renders its LEDs purely from
a state frame loopy pushes back over **bidirectional USB-MIDI**. All looper logic
(per-track state machine, mode, armed track, banks, volumes, the record cycle) lives
in loopy; the firmware holds **no** looper state. This kills today's two-sources-of-truth
problem where the firmware keeps its own `State[]` machine and blindly fires Mobius
notes.

The **firmware is a full ground-up rewrite** (not a patch of the old sketch), and this
work **reuses the native USB-MIDI device plumbing** planned in
[2026-06-14-feat-native-midi-device-selection-plan.md](../plan/2026-06-14-feat-native-midi-device-selection-plan.md)
for transport, adding a dedicated bidirectional **pedal protocol** on top.

## Why This Approach

- **Single source of truth.** State lived in two places (firmware `State[]` + the looper
  app), so they drifted. Moving all state into loopy and pushing it to the pedal makes
  the pedal a display + input surface only — they can never disagree.
- **Native MIDI, reused.** The pedal is a USB-MIDI device; the native MIDI device
  feature already gives loopy enumeration/open/capture. This feature adds the *output*
  (state push) + a device-specific protocol, rather than a new transport.
- **Dedicated pedal module (VGV).** The pedal is bidirectional + stateful + device-
  specific (handshake, SysEx state out, mode-aware command logic, thin-client
  rendering). The generic `ControllerSource` is intentionally one-way and stateless, so
  the pedal gets its **own module** that reuses the MIDI transport but owns the protocol;
  the generic controller-mapping path stays untouched for arbitrary controllers.

## Control Surface

**10 foot buttons, fixed physical order** (positions unlabeled on the hardware; meaning
is defined here). The old **"Next" button is removed**; **"X2" → "Bank"**:

`Rec/Play · Stop · Undo · Mode · Track 1 · Track 2 · Track 3 · Track 4 · Clear · Bank`

Plus one **rotary encoder** (turn + push), separate from the 10 buttons.

**Global concepts (all loopy-owned):**
- **Mode** — *Rec* or *Play*, toggled by the Mode button. Changes what Rec/Play, Stop,
  and the track buttons do.
- **Armed track** — the track that **Rec/Play** records/acts on. Exactly **one** track is
  armed at a time; **default = Track 1** on a clean/reset pedal. When no track is recording,
  pressing a track button **arms** that track (it does not start recording — recording
  begins only when **Rec/Play** is pressed). The armed track is also the target of **Undo**.
  No on-pedal visual indicator (the old breathing/selection emphasis is dropped). *(Replaces
  the old "selected track" cursor.)*
- **Bank** — **always two banks of 4** (tracks 0–3 = A, 4–7 = B), toggled by Bank.
- **Rec cycle** — a loopy **setting** controlling what a track does when its **first
  recording is finished**: go to **Play** *or* go to **Overdub**.

### Per-button behavior

| Button | Rec mode | Play mode |
|--------|----------|-----------|
| **Rec/Play** | Act on the **armed** track: if it is idle (not recording), **start recording** it; if it **is** recording, **finish the loop** then **play or overdub** (per the rec-cycle setting). | **Toggle the remembered playing-set:** 1st press mutes all currently-playing tracks (remembering them); next press unmutes **only those** (not empty/never-played). |
| **Stop** | **Mute the armed track.** If it is recording/overdubbing, **finish the recording first** (loop kept), then mute it (LED off). | **Mute all currently-playing tracks.** |
| **Undo** | **Tap** = undo last overdub layer on the armed track. **Long-press** = redo. | same |
| **Mode** | Toggle Rec/Play mode. (Mode LED deferred — not driven yet.) See **Mode transition** below. | same |
| **Track 1–4** | **If a track is recording/overdubbing:** pressing the **same** track finishes its loop → play/overdub (per setting); pressing a **different** track finishes the recording track's loop **and immediately starts recording the pressed track** (which becomes armed). **If nothing is recording:** the press **arms** that track (only one armed; recording starts on the next Rec/Play). | **Toggle mute** for that track (instant). |
| **Clear** | **Clear ALL tracks** (configurable fade-out / clear effect). Clear LED lit during the clear/fade. | same |
| **Bank** | Toggle bank A/B. Bank LED lit when **B**. | same |

**Recording / arming model (Rec mode):**

- Exactly one **armed** track at a time; default Track 1 on a clean pedal. Pressing a track
  button while nothing is recording just **re-arms** to that track — recording starts only on
  **Rec/Play**.
- **Rec/Play** on the armed track: idle → **RECORDING**; recording → finish loop → **PLAYING**
  *or* **OVERDUBBING** per the **rec-cycle** setting; an existing loop → overdub/play per
  setting.
- **Track-to-track hand-off:** while a track records, pressing a *different* track button
  finishes the first loop and starts recording the new track in one action (the new track
  becomes armed).
- Re-recording a non-empty track from scratch is via **Clear**, not a track press.

**Mode transition (Rec → Play):** when switching from Rec to Play mode, **any track that is
recording/overdubbing is finalized — recording stops and the track plays.** (Switching
Play → Rec has no special transport effect.)

**Encoder:** turn = **master / output volume** (sent to loopy, persisted by loopy);
push = **unused**.

## State Model & Source of Truth

loopy owns the entire looper state machine; the firmware owns none of it. Concretely,
**all of this is deleted from the firmware**: `State[]` (E/R/O/P/M), `firstRecording`,
`stopMode`/`stopModeUsed`, `playedWithRecPlay[]`, `pressedInStop[]`, `selectedTrack`,
`playMode`, `x2timesPressed`, EEPROM volumes, sleep-mode timers. The firmware emits raw
events; loopy interprets them against the **published `le_snapshot`** (per-track
`le_track_state`, mute, volume, undo/redo depth, master loop position/length) and the
pedal-mode it tracks, then pushes a state frame back.

The **rec-cycle, mute-timing, quantize, and long-press/double-tap timing are loopy
settings** — changing pedal behavior never requires reflashing.

## LED / Feedback Semantics (rendered from loopy's state frame)

- **4 track LEDs:** `red` = recording **or** overdubbing · `green` = playing · `off` =
  empty / stopped / muted. **No selected-track emphasis.**
- **12-LED ring:** a continuous spin **locked so one full revolution = one loop length**,
  colored by global state (`red` recording · `yellow` overdubbing · `green` playing).
  Driven by **loop length + a loop-top sync pulse**; the pedal interpolates the spin
  locally from its own clock between pulses (low MIDI traffic, re-synced each loop).
- **Clear LED:** lit while a clear/fade-out is in progress (driven by a flag in the state
  frame, not local logic).
- **Bank LED:** lit when bank **B** is active.
- **Mode LED:** **deferred** — not driven for now.
- **Startup/handshake animation:** kept, but triggered by loopy's "hello" frame on bind
  (not a local power-on routine).

## Protocol (loopy ↔ pedal)

- **Transport:** class-compliant **bidirectional USB-MIDI** (Atmega16u2 flashed to a
  USB-MIDI device; IN + OUT). The pedal can receive SysEx.
- **Pedal → loopy events:** **one fixed MIDI Note per button** (NoteOn = press, NoteOff =
  release) so loopy times **tap / double-tap / long-press**; the **encoder = a relative
  CC** (increment/decrement). Fits the existing `midiNote`/`midiCc` model.
- **loopy → pedal state:** a compact **SysEx state frame** carrying the full visible
  state, pushed **on change** (frames also serve as the render source for the LEDs).
  Sketch of fields: protocol version · global state/color · per-track state for **all 8**
  tracks (so a bank switch renders instantly with no round-trip) · active bank · armed
  track · mode · loop length · clear/fade-active flag. The **loop-top pulse** is a small
  separate message for ring sync.
- **Identity / auto-detect:** loopy auto-detects the pedal via a **SysEx handshake** (sends
  an identity request; the pedal firmware replies with a signature); loopy auto-binds and
  starts streaming, with a manual override available. This is how loopy distinguishes the
  pedal from a generic MIDI controller.
- **Liveness:** **USB connect/disconnect only** (no heartbeat). While the USB link is up
  the pedal assumes loopy is present; on USB loss it shows the disconnected display. loopy
  sends a **blank/goodbye frame** on app shutdown so the pedal darkens even if USB stays
  powered.

## Architecture (loopy side)

A **dedicated pedal module** (proposed `pedal_repository` + a pedal controller
bloc/cubit), reusing the native MIDI transport:

- **Data/transport:** the native USB-MIDI seam (from the MIDI device-selection feature) —
  raw MIDI in/out, including SysEx.
- **Repository:** owns the **pedal protocol** — handshake/auto-detect, decode inbound
  Notes/CC → pedal button/encoder events, encode loopy state → outbound SysEx frames + the
  loop-top pulse. Exposes an inbound event stream and a `pushState(...)` method.
- **Feature (bloc/cubit):** holds the **pedal-mode state machine** (Rec/Play mode,
  armed track, bank, rec-cycle setting), maps button events → `LooperRepository`
  commands (record/stop/play/clear/undo/redo/mute, master volume), and **projects the
  looper snapshot → pedal state frames**. The generic `controller_repository` is untouched.

## Configurable Settings (loopy)

- **Rec-mode cycle** (`Record→Play→Overdub` vs `Record→Overdub→Play`).
- **Clear fade-out / clear effect** (on/off + length) — the "note for later".
- **Quantize to loop top** (whether start/stop/mute actions snap to the loop boundary).
- **Long-press / double-tap timing** (hold duration for redo; double-tap window).

## Deprecations (all confirmed) + Full Rewrite

Dropped: the pedal-local `State[]` machine and all its bookkeeping; the **Mobius note set
(0x1E–0x32)**; **EEPROM volume persistence**; **sleep mode**; **per-track encoder volume**
(now master output); **selected-track breathing/emphasis**; the **loop-length "X2"
doubling** (loop multiples are loopy-side only); the **"Next" button**; and loopy's
**bank-enable setting** (banking is always on). The **firmware is rewritten from scratch**
around the thin-client protocol. A startup/handshake LED animation is kept (loopy-triggered).

## Open Questions (for the planning phase)

- **Master output gain in the engine.** The encoder controls "master/output volume," but
  the engine currently exposes only per-track/per-lane volume — **no global output gain**.
  The plan must add a master output gain (FFI + engine) or define what "master volume"
  maps to.
- **Bank-enable removal impact.** loopy's `BankCubit`/`BankState.enabled` and its persisted
  setting are being dropped (always 2 banks). Confirm UI/storage migration.
- **Accidental clear-all guard.** Clear = clear **all** on a single press is destructive
  mid-performance. Decide whether a guard (hold, or the fade acting as an undo window) is
  needed, or rely on Undo/redo.
- **SysEx specifics.** Manufacturer/SysEx id (e.g. the non-commercial `0x7D` id), exact
  frame byte layout + version field, MIDI channel default + configurability, frame size,
  and whether the loop-top pulse is a Clock/Start real-time message or custom SysEx.
- **Mode LED** — deferred now; define its meaning when re-enabled (red=Rec/green=Play was
  the legacy).
- **Pedal-mode persistence** — does loopy persist the pedal's last mode / armed track /
  active bank across launches, or reset on bind (default: reset)?
- **Two pedals / re-bind** — behavior if a second matching pedal appears, and re-handshake
  after reconnect.
- **Firmware toolchain** — *resolved:* firmware lives **in-repo under `firmware/`** (UNO +
  flashed 16u2 dualMocoLUFA, FastLED). Remaining: sketch structure + how the protocol is
  contract-tested against loopy (shared golden SysEx fixtures).

*(Resolved by the arming model: a track press while nothing is recording simply re-arms — it
no longer changes that track's transport, so the old "stopped/muted-in-Rec-mode" question is
moot.)*
