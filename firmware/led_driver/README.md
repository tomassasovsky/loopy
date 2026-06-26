# Loopy floor-console LED driver (RP2040)

Drives the floor console's WS2812 ring + per-track indicator LEDs from an RP2040,
offloading the hard-real-time WS2812 timing from the Raspberry Pi. The Pi pushes
compact transport-state frames over UART; the RP2040 renders them and animates
the loop-position ring locally between frames.

The Pi side is [`packages/led_client`](../../packages/led_client); the projection
from looper state lives in `lib/led/cubit/led_cubit.dart`.

> **Status: unverified on hardware.** The firmware and the Pi-side
> `UartLedTransport` are written from this spec but have not been brought up on a
> real RP2040 + ring. Flash and bench-test before relying on them. The LED-vs-
> audio skew (below) must be **measured** on the assembled console.

## Hardware / wiring

- **MCU:** RP2040 (e.g. Adafruit QT Py RP2040 or a Pico).
- **Transport:** UART, **115200 8N1**, on the Pi's UART pins:
  - Pi **TXD (GPIO14)** → RP2040 **Serial1 RX (GP1)**
  - Pi **RXD (GPIO15)** ← RP2040 **Serial1 TX (GP0)**
  - common ground.
  - Enable the Pi UART (`raspi-config` → Interface → Serial: login shell *off*,
    hardware serial *on*) so `/dev/serial0` is the GPIO UART.
- **LEDs:** WS2812 data on RP2040 **GP2** via a 3.3→5 V level shifter; 12-LED
  position ring + 8 per-track indicators (`RING_LEDS` / `TRACK_LEDS` in the
  sketch). Power the LEDs from 5 V, not the MCU.

## Wire format

All frames are little-endian and framed as:

```
[0xA5 sync][type][len][payload …][checksum]
```

- `checksum` = XOR of every byte from `type` through the last payload byte.
- `len` = payload byte count.

### STATE  (Pi → driver, `type = 0x01`)

| offset | bytes | field        | notes                                          |
|--------|-------|--------------|------------------------------------------------|
| 0      | 1     | flags        | bit0 `running`                                 |
| 1      | 1     | global       | ring colour: 0 off, 1 green, 2 red, 3 amber    |
| 2      | 4     | loopLengthUs | master loop length, µs, uint32 LE              |
| 6      | 1     | trackCount   | N (≤ 8)                                         |
| 7      | N     | tracks[]     | per-track colour: 0 off, 1 green, 2 red, 3 amber |

While `running`, the driver shows a moving green ring head even when `global` is
off, so the ring is never dark mid-loop.

The driver animates the ring head from `loopLengthUs` + its own clock and
resyncs on each frame, so the Pi sends a STATE frame only on a **state change**
(transport cadence), never at audio rate. Unchanged frames are diffed away on the
Pi (`LedRepository.pushFrame`).

### PING / ACK  (health handshake)

- **PING** (Pi → driver, `type = 0x02`, no payload): `A5 02 00 02`.
- **ACK** (driver → Pi, `type = 0x82`, no payload): `A5 82 00 82`.

At boot the Pi sends one PING and waits up to 2 s for an ACK
(`LedRepository.start`). No ACK → the app shows a persistent "LED driver not
responding" banner. The handshake is intentionally stateless — no sequence
numbers, no keep-alive.

## Flashing

1. Install the Arduino **Raspberry Pi Pico/RP2040** core and the **Adafruit
   NeoPixel** library.
2. Open `led_driver.ino`, select the RP2040 board, and upload (BOOTSEL for the
   first flash).

With `arduino-cli`:

```bash
arduino-cli compile -b rp2040:rp2040:rpipico firmware/led_driver
arduino-cli upload  -b rp2040:rp2040:rpipico -p /dev/ttyACM0 firmware/led_driver
```

## LED-vs-audio skew budget

Separate from the looper's ≤10 ms **audio** action-latency gate: the LED path
adds its own latency (state projection → UART tx → render). Budget and rationale:

- **Target: ≤ 30 ms** from a transport state change to the LEDs reflecting it —
  imperceptible against a foot stomp, and well under one beat at typical tempos.
- **Components:** projection + diff on the Pi (sub-ms) + a STATE frame of
  ≤ ~30 bytes at 115200 (~2.6 ms) + the driver's ≤16 ms render tick. Sum
  ≈ 19 ms, inside budget.
- The **ring animation** is local to the driver, so playhead motion is smooth
  regardless of frame cadence; only discrete state changes pay the skew.
- **Must be measured** on the assembled console (frame-accurate capture of a
  stomp → LED change) and recorded here once hardware exists.
