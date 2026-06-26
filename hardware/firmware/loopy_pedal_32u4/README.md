# loopy pedal — ATmega32U4 firmware skeleton

Firmware for the **THT main-board re-spin**
(`../../loopy_pedal_pcb_tht_plan.md`), built around an **Arduino Pro Micro
(ATmega32U4, USB-C, 5 V/16 MHz)** module that replaces the 328P + 16U2. The module
mounts in the board interior and its USB-C is cable-extended to the faceplate.

Unlike the old [`loopy_pedal_328p`](../loopy_pedal_328p/) skeleton — which emitted
one UART stream that a separate 16U2 (MocoLUFA) bridged to USB — the 32U4 is a
**native, class-compliant USB-MIDI device** (via the `MIDIUSB` library) over the
module's USB-C **and** drives the DIN-5 MIDI OUT over the hardware UART
(`Serial1`, 31250 baud). The two are independent transports: **no MocoLUFA, no
74HC08 AND-merge.** Both MIDI inputs (USB and DIN-in on `Serial1` RX) are read for
bidirectional sync with the app.

## Pin / note map

The board wires the 32U4 ports so the Arduino pin numbers below are unchanged
(see `../../loopy_pedal_pcb_tht_plan.md` §1 and `main_board.py`):

| Arduino pin | footswitch | note | | Arduino pin | footswitch | note |
|---|---|---|---|---|---|---|
| D2 | RECPLAY | 0 | | D7  | TRACK2 | 5 |
| D3 | STOP    | 1 | | D8  | TRACK3 | 6 |
| D4 | UNDO    | 2 | | D9  | TRACK4 | 7 |
| D5 | MODE    | 3 | | D10 | CLEAR  | 8 |
| D6 | TRACK1  | 4 | | D14 | BANK   | 9 |

Other I/O: **D15** ring-LED data, **D16** indicator-LED data, **A0/A1/A2** encoder
A/B/SW, **D0/D1** DIN MIDI in/out, **A3** spare. Switches read **active-low**
(internal pull-ups, LOW = pressed).

> `NOTE_BASE` defaults to 0. Set it to whatever the loopy app listens for — that
> mapping is the single source of truth.

## Build

1. Arduino IDE → Library Manager → install **MIDIUSB**.
2. Board: **SparkFun Pro Micro (5V/16MHz)** (add the SparkFun AVR boards URL) or
   **Arduino Leonardo** (same ATmega32U4 core).
3. `#define MIDI_DEBUG 0`, flash over the module's USB-C (the module is
   pre-bootloaded; a 1200-baud touch enters the bootloader).

## Verify

1. Power up — the pedal enumerates as a **USB-MIDI** device with no extra drivers.
2. Open a MIDI monitor / the loopy app and watch **notes 0–9** as you press each
   footswitch.
3. Loop **DIN OUT → DIN IN** with a cable to exercise the H11L1 opto input path;
   incoming MIDI lands in `handleIncoming()`.

For logic-only testing without hardware, set `#define MIDI_DEBUG 1` and watch the
USB serial monitor at 115200 — `NoteOn ch=1 note=4 vel=127` on press, `NoteOff …`
on release.

## What's a TODO

This is a **bring-up skeleton** (footswitch→MIDI + MIDI-in read), parallel to the
328P one. The looper state machine, the `FastLED` two-strip output (indicator +
ring, hooks marked in `setup()`), and the encoder→action mapping are stubbed where
the comments mark them.
