# Loopy Floor Console — Local Shopping List (Argentina)

Quantities are **per console**. All parts are standard and available at local
electronics shops / MercadoLibre, except the Pi 5, screens, and USB interface
(import or specialty). Mirrors [`loopy_pedal_shopping_list.md`](loopy_pedal_shopping_list.md).

> The console is a **standalone Pi 5 appliance**, separate from the 32U4
> USB-MIDI pedal. The WS2812 LEDs are offloaded to a small RP2040 driver over
> UART (see [`firmware/led_driver/README.md`](../firmware/led_driver/README.md));
> the Pi never bit-bangs WS2812.

---

## Compute + displays

- [ ] Raspberry Pi **5** (8 GB recommended; 4 GB OK) ×1
      *(Pi 4 Model B 8 GB also works — see the Pi-4 note in
      [`docs/RUNNING_ON_RPI.md`](../docs/RUNNING_ON_RPI.md); tighter latency/thermal margin.)*
- [ ] Pi 5 **active cooler** (official, or a heatsink+fan) ×1 — **required** for a
      closed enclosure under sustained audio + GPU load
- [ ] microSD card, A2, 64 GB+ ×1
- [ ] **16″ touchscreen** monitor, 1080p, HDMI + USB-touch ×1 — main UI
- [ ] **7″ HDMI** display ×1 — waveform. **HDMI, not DSI** (decision below)
- [ ] micro-HDMI → HDMI cables (Pi 5 has 2× micro-HDMI) ×2
- [ ] USB-A → USB-B/-C cable for the touchscreen's touch panel ×1

## Audio

- [ ] USB **class-compliant** audio interface, Scarlett-class (e.g. Focusrite
      Scarlett 2i2 / Clarett, or any UAC2 interface) ×1
- [ ] Instrument (TS) + mic (XLR) cables as needed
- [ ] TS→TS loopback cable ×1 *(one-time latency calibration only)*

## Foot controls

- [ ] Momentary **SPST footswitches** (stomp-rated) ×5 — rec/overdub, stop,
      undo, clear, encoder-press is separate
- [ ] **EC11 rotary encoder** (with push switch) ×1
- [ ] Knob for the EC11 ×1

## LEDs + driver

- [ ] **RP2040** board — Adafruit QT Py RP2040 or a Pi Pico ×1 (the LED driver)
- [ ] WS2812 **ring**, 12 LEDs (loop-position ring) ×1
- [ ] WS2812 **strip/indicators**, ≥8 LEDs (per-track indicators) ×1
- [ ] 3.3 V → 5 V level shifter (e.g. 74AHCT125N, **DIP-14**) ×1 — for the
      WS2812 data line off the RP2040
- [ ] 1000 µF electrolytic, 6.3 V+ ×1 — across the WS2812 5 V rail
- [ ] 330–470 Ω resistor ×1 — in series with the WS2812 data line

## GPIO input protection (per footswitch + encoder line)

3.3 V discipline — Pi GPIO is **not 5 V tolerant**. Footswitches/encoder switch
to **ground** (active-low; `gpio_client` enables the internal pull-up). See
[`hardware/console/README.md`](console/README.md) for the circuit.

- [ ] 1 kΩ resistor (series, per line) ×8  *(5 footswitch + A/B/SW encoder)*
- [ ] 100 nF ceramic ("104"), 50 V (RC debounce to GND, per line) ×8
- [ ] BAT54S or 1N4148 clamp diodes (optional ESD clamp to 3V3/GND) ×8

## Power

- [ ] Raspberry Pi 5 **official 27 W USB-C PD** supply ×1 — Pi 5 alone
- [ ] Separate **5 V / ≥3 A** supply for the WS2812 LEDs + RP2040 ×1
      *(do not draw the LED ring/strip off the Pi's 5 V pin)*
- [ ] The 16″ and 7″ screens use their **own** adapters (USB-C / barrel) ×2
- [ ] Inline fuse / power switch for the mains side ×1
- See the power budget in [`hardware/console/README.md`](console/README.md).

## Mechanical / enclosure

- [ ] Enclosure material (plywood / aluminium / 3D-printed panels) — tilted body
- [ ] M2.5/M3 screws + standoffs for the Pi, RP2040, and screen mounts ×1 set
- [ ] Stomp-panel face (steel/aluminium) for the footswitches ×1
- [ ] Rubber feet / non-slip base ×1 set
- [ ] Cable strain reliefs / grommets ×1 set

---

### 7″ display: **HDMI, not DSI** (spike outcome)

Both screens are wired as **HDMI** outputs, so they enumerate as uniform
`HDMI-A-1` (16″) / `HDMI-A-2` (7″) wlr outputs. This gives clean, deterministic
`wlr-randr` output-name pinning (matching Part 5's
[`deploy/rpi/pin-displays.sh`](../deploy/rpi/pin-displays.sh)) with no DSI ribbon
or DSI-specific compositor mapping. The official 7″ DSI panel's only advantage —
freeing a micro-HDMI port — is moot here since nothing else uses the second
HDMI, and its 800×480 is lower-res than an HDMI 7″. Resolution matters little for
a waveform, so pick any 7″ HDMI panel; set its per-output `--scale` in
`pin-displays.sh`.

### Notes

- Keep the engine at **48 kHz** with the PipeWire **Pro Audio** profile for the
  full channel count + lowest stable latency (see
  [`docs/RUNNING_ON_LINUX.md`](../docs/RUNNING_ON_LINUX.md)).
- The RP2040 LED driver talks UART to the Pi (GPIO14/15) — see the firmware
  README for wiring + the wire-format spec.
- No console PCB is fabbed yet; the foot controls + protection passives are
  point-to-point or on protoboard. Enclosure/fab files live under
  `hardware/console/` once designed.
