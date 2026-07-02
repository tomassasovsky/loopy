# Loopy Floor Console — hardware design

Hardware for the standalone Pi 5 floor console: GPIO input protection, the
power/thermal budget, and the enclosure. The BOM is
[`hardware/loopy_console_shopping_list.md`](../loopy_console_shopping_list.md).

> **Status: design + budget only.** This documents the circuit and the budgets;
> the enclosure CAD/fab files and the assembled-unit gates (latency soak,
> miswire test, stage-abuse) are physical work, tracked as the on-hardware
> checklist in [`docs/RUNNING_ON_RPI.md`](../../docs/RUNNING_ON_RPI.md).

## GPIO input protection (3.3 V discipline)

Pi GPIO is **3.3 V and not 5 V-tolerant**. Footswitch and encoder lines run
longer inside the enclosure than on a handheld pedal, so they pick up ESD and
contact-bounce transients; an over-voltage or a miswire can kill a pin. Every
input line gets the same simple network:

```
            1 kΩ
 GPIOxx ───/\/\/──┬───────────┬─────────  switch / encoder pin
                  │           │
                100 nF      (BAT54S)       switch other side ── GND
                  │        clamp to
                 GND       3V3 / GND
```

- **Series 1 kΩ** limits fault current into the pin (a miswire to 5 V, or ESD)
  to a level the Pi's internal clamp diodes survive — the primary protection.
- **100 nF to GND** forms an RC low-pass (~100 µs) that knocks down fast
  transients. Software still debounces (`GpioControllerSource` leading-edge +
  sanity gate), so this is belt-and-braces, not the debounce of record.
- **Optional BAT54S** (dual Schottky) clamps the pin to 3V3 / GND for hard ESD;
  on a tidy build the series-R + the Pi's internal clamps suffice.
- **Active-low wiring**: switches connect the line to **GND**; the line idles
  high via the GPIO's internal pull-up (`gpio_client` requests pull-up bias).
  Never wire a switch to 5 V.

Default pins (BCM, from `gpio_client`): footswitches **17, 27, 22, 23**, encoder
push **26**, encoder A/B **5, 6**. (On a Pi 4 these are `/dev/gpiochip0`; on a
Pi 5 the same header is behind RP1 — see the Pi-4/5 note in
`docs/RUNNING_ON_RPI.md`.)

**Miswire test (on-hardware gate):** with protection fitted, briefly touch a 5 V
rail to each input through the network and confirm the pin still reads correctly
afterward — no damage.

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
