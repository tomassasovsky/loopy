# MIDI foot-controller setup

Loopy can be driven hands-free from a USB MIDI foot controller so you can
record, stop, undo, and clear loops with your feet while both hands play.

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
the device is unplugged it is kept pinned — replug it and Loopy re-attaches on
its own. Switching or losing a MIDI device never restarts the audio engine, and
the picker is available even on Windows (ASIO-only) builds.

## Required control changes

The v1 mapping is fixed to four Control Change messages on **track 0**
(channel-agnostic):

| CC  | Action                                   |
| --- | ---------------------------------------- |
| 80  | Record → finalize → overdub (toggles)    |
| 81  | Stop                                     |
| 82  | Undo                                     |
| 83  | Clear                                    |

Configure your foot controller to send these CCs. Use **momentary** switches: a
press (value > 0) triggers the action; a release (value 0) does nothing. A short
same-trigger debounce collapses switch bounce so one stomp is one action.
Latching switches are not supported in v1, and there is no remap UI yet.

## Troubleshooting

- **"No MIDI input devices found"** — the host exposes no MIDI input ports. Plug
  in the controller (and on Linux ensure it appears under `aconnect -i`).
- **"Could not open … (in use?)"** — another application holds the port. Close
  it and re-select the device; the pin is retained so a retry recovers.
- **The activity indicator never blinks** — the pedal is connected but sending
  something other than Note/CC (e.g. clock); check its CC assignments above.
