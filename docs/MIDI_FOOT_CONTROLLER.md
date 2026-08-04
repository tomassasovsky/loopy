# MIDI foot-controller setup

Segno can be driven hands-free from a USB MIDI foot controller so you can
record, stop, undo, and clear loops with your feet while both hands play — and,
since FX v3 part 7, sweep parameters from an expression pedal and stomp FX
chains from any MIDI switch.

MIDI input is captured natively on each desktop OS (CoreMIDI on macOS, the ALSA
sequencer on Linux, WinMM on Windows), so there is nothing extra to install —
plug the controller in and pick it in settings.

## Selecting a device

1. Open **Settings** (right-click the looper, or press <kbd>S</kbd>).
2. Under **MIDI FOOT CONTROLLER**, choose your device from the dropdown.
   - Pick **None** to run without MIDI (the looper is fully usable from the
     keyboard and mouse).
3. The status line shows the live connection; the activity indicator blinks on
   every incoming MIDI message so you can confirm the pedal is talking.

Your choice is remembered and reconnects automatically on the next launch. If
the device is unplugged it is kept pinned — replug it and Segno re-attaches on
its own. Switching or losing a MIDI device never restarts the audio engine, and
the picker is available even on Windows (ASIO-only) builds.

## Built-in transport mapping

The built-in transport mapping is fixed to these Control Change messages on
track 0, and is channel-agnostic (it fires whatever MIDI channel the controller
is set to):

| CC  | Action                                   |
| --- | ---------------------------------------- |
| 80  | Record → finalize → overdub (toggles)    |
| 81  | Stop                                     |
| 82  | Undo                                     |
| 83  | Clear                                    |
| 84  | Tap tempo                                |
| 85  | Toggle the click                         |
| 86  | Cancel a pending record arm              |

Configure your foot controller to send these CCs. Use **momentary** switches: a
press (value > 0) triggers the action; a release (value 0) does nothing. A short
same-trigger debounce collapses switch bounce so one stomp is one action.

## External MIDI control (mappings)

Everything below is configured under **EXTERNAL MIDI CONTROL**, in the same
Audio settings section as the pickers above. A mapping has two halves: the
control it listens to, and what that control drives.

### The two trigger shapes

- **Sweep (continuous)** — the CC's absolute `0..127` position is mapped onto a
  **LO/HI** range and written to one target: an effect parameter, a track's
  volume, or the master gain. This is what an expression pedal is for. LO and HI
  are set with the two knobs on the row, in the target's own normalized `0..1`
  domain; setting LO **above** HI inverts the pedal (heel-down loud).
- **Switch (discrete)** — the CC crossing a **threshold** stomps an FX chain or
  a single effect on and off, with the same **toggle / momentary** behaviors a
  Segno pedal footswitch binding has. Toggle latches; momentary is held (the
  press captures the target's state and the release puts it back). A small
  hysteresis band under the threshold means a controller resting on the boundary
  or dithering around it holds its state instead of chattering.

Values are smoothed: a 7-bit CC step ramps to its new value rather than jumping,
so a filter sweep is smooth rather than stepped.

### Learning a control

1. Press **Add sweep** or **Add switch** and pick the target from the list.
2. The row says *"Listening… move the control you want to use"*. Move the
   expression pedal, or stomp the switch.
3. The mapping is created. Press **Learn** on an existing row to re-point it at
   a different control — its LO/HI (or threshold and behavior) are kept.

**Learn hygiene.** The Segno pedal's own protocol traffic — its footswitch notes
and its encoder CC — is ignored while learning, so you can learn a third-party
controller with the Segno pedal plugged in and stomping will not capture it.

If the control you move is already mapped, the row asks before replacing that
mapping — **Replace** takes the control over, **Keep** leaves things as they
were and ends the capture. A capture nobody feeds times out on its own (all MIDI
is swallowed while one is pending, so it never stays open).

### Takeover, fan-out, and who wins

- **Takeover is jump-on-first-move.** The first time a mapped control moves, the
  target jumps straight to the mapped value. There is no pickup/catch mode in
  v1 — a parameter goes wherever the control already is.
- **Fan-out is allowed at the model level**: one control can drive several
  targets (a single expression pedal sweeping more than one parameter). The
  settings UI creates one mapping per learn and replaces on conflict; a fanned
  out map is preserved if it exists.
- **Many controls on one target are last-writer-wins**, and so is a CC racing an
  on-screen knob: whichever moved last wins, with no reconciliation.

### Where mappings are stored

Mappings are **global** — one `controller.mappings` blob in settings, not part
of any session. Expression hardware belongs to the rig, not the song: the pedal
plugged into this machine is the same one whatever session is loaded, and a
session carrying its own CC map would either fight the rig it was opened on or
stop being portable between machines. (The Segno pedal's own footswitch remap is
the deliberate exception — its layout IS part of an arrangement, so a session
can carry one.)

### Disconnects and missing targets

- **A held momentary releases when the MIDI device unplugs.** The release edge
  is never coming, so the target is restored to what the press captured rather
  than being left stuck on.
- **A swept value HOLDS on unplug.** No snap-back: a filter stays exactly where
  the last sweep left it, because a cable wobble silently rewriting your sound is
  the louder failure.
- **With no MIDI input connected**, every row renders inert with a note saying
  so, and each row's button becomes **Relearn** — one tap re-points that mapping
  at whatever controller is plugged in now.
- **A mapping whose target no longer exists** (the effect was deleted, the chain
  is gone) is kept and shown as *Missing target*. It does nothing until it is
  re-pointed or removed — it never falls back to whatever effect took its place.

Hosted VST3/CLAP plugin parameters cannot be mapped yet; built-in effect
parameters, track volume, and master gain can.

## Troubleshooting

- **"No MIDI input devices found"** — the host exposes no MIDI input ports. Plug
  in the controller (and on Linux ensure it appears under `aconnect -i`).
- **"Could not open … (in use?)"** — another application holds the port. Close
  it and re-select the device; the pin is retained so a retry recovers.
- **The activity indicator never blinks** — the pedal is connected but sending
  something other than Note/CC (e.g. clock); check its CC assignments above.
- **A learn never catches anything** — the control may be sending on a channel
  the app never sees (check it is a CC or Note, not aftertouch or pitch bend),
  or it may be the Segno pedal itself, which learn ignores by design.
