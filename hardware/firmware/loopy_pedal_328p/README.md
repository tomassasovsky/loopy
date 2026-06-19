# loopy pedal — ATmega328P firmware skeleton

Footswitch → MIDI logic for the loopy MIDI foot-pedal main board. Reads the 10
footswitches and emits MIDI Note On/Off over the hardware UART. On the board that
UART feeds **both** the ATmega16U2 (→ USB-MIDI) and the 74AHCT125 buffer (→ DIN-5
MIDI OUT), so this single stream drives both outputs.

This is a **bring-up skeleton** — enough to prove the footswitch→MIDI path before
the PCB exists. The looper state machine (RECPLAY/MODE/BANK semantics, reading
MIDI back for bidirectional sync with the loopy app) goes where the comment marks
it in `loop()`.

## Pin / note map

Matches `../../loopy_pedal_pcb_design.md` exactly:

| Arduino pin | footswitch | note | | Arduino pin | footswitch | note |
|---|---|---|---|---|---|---|
| D3  | RECPLAY | 0 | | D8  | TRACK2 | 5 |
| D4  | STOP    | 1 | | D9  | TRACK3 | 6 |
| D5  | UNDO    | 2 | | D10 | TRACK4 | 7 |
| D6  | MODE    | 3 | | D11 | CLEAR  | 8 |
| D7  | TRACK1  | 4 | | D12 | BANK   | 9 |

Switches are wired pin1→MCU, pin2→GND, so they read **active-low** with the
internal pull-ups (LOW = pressed).

> `NOTE_BASE` defaults to 0 to match the design doc. Set it to whatever the loopy
> app actually listens for — that mapping is the single source of truth.

## Run it in Wokwi (no hardware needed)

1. Go to <https://wokwi.com>, create a new **Arduino Uno** project (the Uno is an
   ATmega328P @ 16 MHz — same core as this board).
2. Replace `sketch.ino` with `loopy_pedal_328p.ino` and replace `diagram.json`
   with the one here (Uno + 10 labelled buttons already wired to D3–D12 / GND).
3. Keep `#define MIDI_DEBUG 1`, run, open the Serial Monitor, and click a button:
   you'll see e.g. `NoteOn  ch=1 note=4 vel=127` on press and `NoteOff …` on
   release. That proves the debounce + mapping logic.

## Build for real hardware

Set `#define MIDI_DEBUG 0`. The UART then runs at **31250 baud** and writes raw
3-byte MIDI messages. Flash via the ICSP-328P header (with an Arduino bootloader
the board enumerates as a serial port through the 16U2).

## Verify the full MIDI path on hardware

1. Flash, power up — confirm the 16U2 enumerates as a USB-MIDI device.
2. Open a MIDI monitor (MIDI-OX, your DAW, or the loopy app) and watch notes 0–9
   as you press each footswitch.
3. Loop DIN MIDI OUT → MIDI IN with a cable to exercise the H11L1 opto input path.
