# loopy pedal — ATmega32U4 firmware

Firmware for the **THT main-board re-spin**
(`../../loopy_pedal_pcb_tht_plan.md`), built around an **Arduino Pro Micro
(ATmega32U4, USB-C, 5 V/16 MHz)** module that replaces the 328P + 16U2. The module
mounts in the board interior and its USB-C is cable-extended to the faceplate.

It is a **pure thin client**, ported from [`firmware/loopy_pedal/`](../../../firmware/loopy_pedal/)
(the UNO/MocoLUFA build): it holds **no** looper state, renders its LEDs only from
the state frames loopy pushes, and sends raw footswitch / encoder events. loopy
runs the behavior machine and is the single source of truth. The wire protocol
lives in `pedal_protocol.c/.h`, **mirrored byte-for-byte** from the canonical copy
(the host contract test guards it) — keep them in sync:

```sh
diff ../../../firmware/loopy_pedal/pedal_protocol.h pedal_protocol.h   # must be empty
diff ../../../firmware/loopy_pedal/pedal_protocol.c pedal_protocol.c   # must be empty
```

Unlike the old [`loopy_pedal_328p`](../loopy_pedal_328p/) skeleton — which emitted
one UART stream that a separate 16U2 (MocoLUFA) bridged to USB — the 32U4 is a
**native, class-compliant USB-MIDI device** (via the `MIDIUSB` library) over the
module's USB-C **and** drives the DIN-5 MIDI OUT over the hardware UART
(`Serial1`, 31250 baud). The two are independent transports: **no MocoLUFA, no
74HC08 AND-merge.** Both MIDI inputs (USB and DIN-in on `Serial1` RX) are read for
bidirectional sync — SysEx state frames + the `0xFA` loop-top pulse — and outbound
events + the identity reply go to **both** transports.

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
(internal pull-ups, LOW = pressed). Notes 0–9 match `PedalButton` in the app.

## LED strips

Two WS2812 strips, each rendered from loopy's state frame:

- **Ring (D15)** — the off-the-shelf **16-LED NeoPixel ring**; a brightness hump
  rotates **clockwise** as the loop plays (red recording / amber overdub / green
  play), freezes on Stop, animates to dark on clear. It also doubles as a
  **volume meter**: whenever the master gain changes, the ring shows a green→red
  level bar for ~1.2 s, then reverts. The gain is **authoritative from the state
  frame** (payload byte 16, `master_gain`), so the meter matches the engine
  exactly — from an encoder turn OR an on-screen control. Before the first frame
  (bring-up, no app) it falls back to a local encoder echo.
- **Indicator (D16)** — a **7-LED** strip wired in this fixed order:

  | index | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
  |---|---|---|---|---|---|---|---|
  | role | mode/global | Tr1 | Tr2 | Tr3 | Tr4 | clear-fade | bank |

> **Link watchdog:** loopy re-sends the current state frame on a **~1 Hz
> heartbeat** while bound (`ControlCubit`'s `keepAliveInterval`), not only on
> change. So the firmware treats a gap of `kLinkTimeoutMs` (2.5 s) with **no
> frame** as a dropped link — USB unplugged or the app closed — and **blanks both
> strips** instead of freezing on the last lit frame. It resumes automatically:
> the next frame refreshes the watchdog and normal rendering picks up where the
> app left off. (This is why the heartbeat exists — without it a stopped, idle
> loop would look identical to a dead link.)

> **Power + phantom gate:** both strips run off the **`+5V_LED`** rail, which the
> on-board buck makes from the **9 V barrel** — connect the 9 V (centre-negative)
> supply to light them. On **USB-only** the buck is off, but the strips would
> otherwise **phantom-power** through their DIN diodes (the MCU drives the data at
> 5 V while the rail floats). So the firmware **gates the LED output on a 9 V
> sense**: a **100k/47k divider from `+9V` to A3** (`LED_PWR_SENSE` in
> `main_board.py`); with no 9 V it holds the data lines LOW and clears the strips.
> Values (the Pro Micro back-feeds `RAW` from USB — RAW ≈ VBUS, per the SparkFun
> schematic, not clone-specific — so A3 never reaches 0):
>
> | | A3 (analogRead) | strips |
> |---|---|---|
> | USB only | ~335 (~1.6 V) | dark (gated) |
> | + 9 V | ~580 (~2.8 V) | driven; self-test on connect |
>
> `#define LED_POWER_SENSE 0` in the sketch if the divider isn't fitted (LEDs
> always driven — they will phantom-glow on USB-only). Tune `kLedPowerThreshold`
> (default 450) if your board reads differently.

## Build

1. Arduino IDE → Library Manager → install **MIDIUSB** and **FastLED**.
2. Board: **SparkFun Pro Micro (5V/16MHz)** (add the SparkFun AVR boards URL) or
   **Arduino Leonardo** (same ATmega32U4 core).
3. Flash over the module's USB-C (the module is pre-bootloaded; a 1200-baud touch
   enters the bootloader). The Arduino build compiles `pedal_protocol.c` in this
   folder automatically.

### Flashing from the CLI (branded USB name)

The AVR core bakes the USB **product** string (`USB_PRODUCT`) and **PID** into the
core at compile time — the sketch can't override them. To make the pedal enumerate
as **"VAMP Loopstation"** with its own identity, pass them as build properties.
Compile + upload in one step (`upload` alone does **not** accept
`--build-property`):

```sh
# on-hardware the module enumerates as an ATmega32U4 (Leonardo core), so the
# leonardo FQBN is correct and avoids needing the SparkFun package.
PORT=$(ls /dev/cu.usbmodem* | head -1)
arduino-cli cache clean          # REQUIRED once — see the gotcha below
arduino-cli compile --upload -p "$PORT" \
  --fqbn arduino:avr:leonardo \
  --build-property 'build.pid=0x7D00' \
  --build-property 'build.usb_product="VAMP Loopstation"' \
  --build-property 'build.usb_manufacturer="loopy"' \
  hardware/firmware/loopy_pedal_32u4
```

**Why the custom PID (`0x7D00`).** macOS (CoreMIDI) caches a USB-MIDI device's
name keyed by its **USB signature = VID + PID + serial**, and reads the product
string only the *first* time it sees a given signature. Every stock Arduino +
`MIDIUSB` board shares the same signature (VID `0x2341` / PID `0x8036` / serial
`"MIDI"` — the serial is `MIDIUSB`'s fixed `getShortName()`), so once *any* of them
was seen as "Arduino Leonardo", macOS keeps showing that name for our board too —
surviving a rename, a re-enumeration, a `MIDIServer` restart, even
`sudo killall coreaudiod`. Changing the **PID** gives it a fresh signature, so
CoreMIDI reads the new product string. `0x7D00` reuses the pedal's manufacturer id
(`0x7D`) and collides with no real Arduino PID. (This "squats" Arduino's VID with a
custom PID — fine for a DIY build; swap in your own VID/PID if you ever ship one.)
A leftover offline **"Arduino Leonardo"** may linger grayed-out in Audio MIDI Setup
from before the PID change; remove it there with **Remove Device** if it bothers
you.

> **Gotcha:** `USB_PRODUCT` / `build.pid` live in the cached `core.a`, and
> arduino-cli's core cache key does **not** include these build properties — so
> after changing them the change is silently ignored until you wipe the cache.
> Run `arduino-cli cache clean` before the build (verify with
> `strings <build>/…​.ino.elf | grep -i vamp`). macOS shows the product string as
> the USB *Product Name*; the *Vendor Name* stays "Arduino LLC" (derived from the
> VID, not the `iManufacturer` string).

## Verify

1. Power up (with **9 V** connected, so the LED rail is live) — a green comet
   sweeps the ring then the indicator strip: the **boot self-test**. It proves
   both strips are wired and powered before loopy binds.
2. The pedal enumerates as a **USB-MIDI** device (no drivers). Open a MIDI monitor
   / the loopy app and watch **notes 0–9** as you press each footswitch; turning
   the encoder sends relative CC `0x10`.
3. With the loopy app bound, its state frames drive the two strips (ring playhead,
   track colors, mode/clear/bank indicators). Malformed frames are dropped and the
   last good frame is kept; loopy refreshes ~1 Hz so a dropped frame self-heals.
4. Loop **DIN OUT → DIN IN** with a cable to exercise the H11L1 opto input path;
   incoming MIDI is parsed by the same SysEx assembler as the USB path.

## Scope

Full thin-client parity with the UNO build: footswitch→Note, encoder→CC, the
SysEx state-frame renderer over both transports, the identity reply, and the
two-strip FastLED output. The encoder push-switch (**A2**) and the spare **A3**
are read-configured but unmapped (v1, matching the original).
