# loopy foot-pedal firmware

A **pure thin client** for the loopy bidirectional MIDI looper pedal. It holds
no looper state: it renders its LEDs only from the state frames loopy pushes and
sends raw footswitch / encoder events. loopy runs the behavior state machine and
is the single source of truth — see
[`docs/plan/2026-06-14-feat-looper-pedal-protocol-firmware-plan.md`](../docs/plan/2026-06-14-feat-looper-pedal-protocol-firmware-plan.md).

```
loopy ── SysEx state frames + loop-top pulse (0xFA) ──▶ pedal renders LEDs
pedal ── Notes (footswitches) + relative CC (encoder) ──▶ loopy runs the machine
```

## Layout

| file | purpose |
|------|---------|
| `loopy_pedal/loopy_pedal.ino` | the Arduino UNO sketch (thin client) |
| `loopy_pedal/pedal_protocol.h` / `.c` | the SysEx codec — the shared wire contract |
| `test/test_pedal_protocol.c` | host-compiled contract test vs the golden fixtures |

`pedal_protocol.c` is the **exact same** wire format as loopy's Dart
`PedalCodec` (`packages/pedal_repository`). The host test below links that unit
and checks it against the committed golden `.syx` fixtures loopy generated, so
both sides are guaranteed to agree byte-for-byte.

## Building the sketch

Requires the [FastLED](https://github.com/FastLED/FastLED) library and the
Arduino UNO toolchain (`arduino-cli` or the IDE). The Arduino build compiles
every `.c`/`.cpp`/`.ino` in the sketch folder, so `pedal_protocol.c` is picked up
automatically.

```sh
arduino-cli compile --fqbn arduino:avr:uno firmware/loopy_pedal
arduino-cli upload  --fqbn arduino:avr:uno -p <PORT> firmware/loopy_pedal
```

**Upload first, flash MIDI second:** the sketch is uploaded over the stock
USB-serial firmware. Only *after* the sketch is on the board do you reflash the
16U2 to dualMocoLUFA (below) to turn the USB port into a class-compliant MIDI
device. To upload a new sketch later, flash the **stock** Arduino USB-serial
firmware back onto the 16U2 first.

## USB-MIDI via dualMocoLUFA (the 16U2)

The UNO's ATmega16U2 normally presents a USB-serial port. The
[dualMocoLUFA](https://github.com/kuwatay/mocolufa) firmware makes it a
**USB-MIDI** device that bridges to the ATmega328P's hardware serial at 31250
baud — which is why the sketch uses `Serial.begin(31250)` and the MIDIUSB library
is **not** usable here (it is 32U4-only).

Stock dualMocoLUFA enumerates as USB product "MocoLUFA". loopy's pedal is
branded VAMP, so we build from source with
[`mocolufa-vamp-rename.patch`](mocolufa-vamp-rename.patch) applied, which
renames the USB-MIDI product string to "VAMP Loopstation":

```sh
# one-time build setup
git clone https://github.com/kuwatay/mocolufa
curl -LO http://www.fourwalledcubicle.com/files/LUFA/LUFA-100807.zip
unzip LUFA-100807.zip -d mocolufa/../  # unpacks alongside mocolufa/, per makefile's LUFA_PATH
cd mocolufa
patch -p1 < /path/to/firmware/mocolufa-vamp-rename.patch
make clean && make   # produces dualMoco.hex
```

Put the 16U2 in DFU mode (briefly short the 16U2 RESET pin to GND — the two pads
near the USB connector), then:

```sh
# erase, flash the patched dualMoco.hex, restart
dfu-programmer atmega16u2 erase
dfu-programmer atmega16u2 flash dualMoco.hex
dfu-programmer atmega16u2 reset
```

dualMocoLUFA boots in MIDI mode by default; hold the mode jumper (see its README)
at power-on to fall back to serial mode for re-uploading the sketch.

## Pin map & LED order

Set in `loopy_pedal.ino` to match the original "aquiles LoopStation" wiring
(verified on hardware).

**LEDs** — a single `WS2812B` strip on pin `D2`, 19 LEDs:

| index | role |
|-------|------|
| 0–11 | the 12-LED loop-position ring (one revolution per loop) |
| 12 | global / mode color |
| 13–16 | the active bank's 4 track indicators (Tr1–Tr4) |
| 17 | clear-fade indicator |
| 18 | bank indicator (lit for bank B) |

**Footswitches** — active-low (`INPUT_PULLUP`), one note each (matching
`PedalButton`):

| pin | button | note |
|-----|--------|------|
| D3 | Rec/Play | 0 |
| D4 | Stop | 1 |
| D5 | Undo | 2 |
| D6 | Mode | 3 |
| D7 | Track 1 | 4 |
| D8 | Track 2 | 5 |
| D9 | Track 3 | 6 |
| D10 | Track 4 | 7 |
| D11 | Clear | 8 |
| D12 | Bank | 9 |

**Encoder** — quadrature on `A0` (clock) / `A1` (data), sends relative CC `0x10`
(binary-offset); loopy maps it to the master output gain. The original "Next"
switch (`A2`) is dropped in this layout.

## Contract test (host, no board)

The firmware's codec is unit-tested on the host against loopy's golden fixtures —
run it from the **repo root** so the default fixtures path resolves:

```sh
gcc -std=c11 -Wall -I firmware/loopy_pedal \
  firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c \
  -o pedal_protocol_tests && ./pedal_protocol_tests
# expected last line: ALL PASSED
```

It decodes every `packages/pedal_repository/test/fixtures/*.syx`, re-encodes it,
and asserts the bytes are identical to the fixture — plus field decodes,
malformed-frame rejection, the identity request, and the Note/encoder encoders.
On-device behavior (LED rendering, debounce, the FastLED poll-around-`show()`) is
covered by the manual per-OS smoke pass.

## Protocol summary

State frame (loopy → pedal), 25 bytes:

```
F0 7D <ver=01> <type=01> <19 packed payload bytes> <checksum> F7
```

The 16-byte logical payload (flags · global color · bank · armed track · 8 track
LEDs · loop length µs) is 7-bit packed and XOR-checksummed. Loop-top is the
single real-time byte `0xFA`. Footswitches send a fixed Note (NoteOn press /
NoteOff release); the encoder sends relative CC `0x10`. See `pedal_protocol.h`
and loopy's `PedalCodec` for the authoritative field table.
