# Loopy Floor Console — hardware design

Hardware for the standalone Pi 5 floor console: the power/thermal budget and
the enclosure. The BOM is
[`hardware/loopy_console_shopping_list.md`](../loopy_console_shopping_list.md).
Footswitches and the encoder connect through the USB-MIDI pedal board
(`loopy_pedal_main`) — the Pi reads no controls directly. The status LEDs
(WS2812 ring + strip) are driven by the RP2040 LED driver over UART, as before.

> **Status: design + budget only.** This documents the budgets; the enclosure
> CAD/fab files and the assembled-unit gates (latency soak, stage-abuse) are
> physical work, tracked as the on-hardware checklist in
> [`docs/RUNNING_ON_RPI.md`](../../docs/RUNNING_ON_RPI.md).

## Power budget

The console runs several loads; budget them and keep headroom. Screens use their
own adapters; the Pi and the LEDs each get a dedicated 5 V feed (the LED ring +
strip must **not** draw off the Pi's 5 V pin).

| Load | Rail | Typical | Peak | Supply |
|---|---|---|---|---|
| Raspberry Pi 5 (+ active cooler) | 5 V | ~5 W | ~25 W | Official 27 W USB-C PD |
| 16″ touchscreen (1080p) | own | ~10 W | ~15 W | Its own adapter |
| 7″ HDMI display | own | ~3 W | ~5 W | Its own adapter |
| USB audio interface | USB bus | ~2.5 W | ~5 W | From the Pi (bus-powered) or own |
| RP2040 LED driver | 5 V | <0.5 W | ~1 W | Shared LED 5 V feed |
| WS2812 ring + strip (~20 LEDs) | 5 V | ~1 W | **~6 W** (all white) | Dedicated 5 V / ≥3 A |

- The Pi 5 wants the **27 W** supply on its own; sharing its USB-C with peripheral
  draw risks under-volt throttling.
- WS2812 peak is ~60 mA/LED at full white; cap brightness in firmware
  (`strip.setBrightness`) to keep the worst case well under the LED supply.
- Add an inline fuse + power switch on the mains side; a single mains inlet can
  feed all the adapters via a small internal power strip.

## Thermals

A Pi 5 in a closed enclosure under sustained audio + dual-display GPU load will
throttle without help:

- **Active cooling is required** — the official active cooler or an equivalent
  heatsink+fan, with an intake/exhaust path in the enclosure.
- **Soak gate (on-hardware):** ≥2 h of audio + dual-display + GPU load in the
  closed enclosure with **no thermal throttle** (`vcgencmd get_throttled` stays
  `0x0`) and no xrun-rate regression. Record results in `docs/RUNNING_ON_RPI.md`.

## Enclosure (design intent — CAD/fab deferred)

- Tilted body: the **16″ touchscreen + 7″ waveform** mounted up top at a
  readable angle; the **footswitch + encoder panel** on the front edge where it
  can be stomped.
- A rigid stomp face (steel/aluminium) for the footswitches; rubber feet /
  non-slip base; strain relief for every external cable.
- Internal mounts for the Pi 5 (with cooler clearance), the RP2040 LED driver,
  the USB interface, and the power distribution.
- Fab files (CAD, panel cuts) land here when designed; this PR is the circuit +
  budgets that gate the physical build.
