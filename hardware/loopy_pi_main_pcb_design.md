# Loopy Pi main board — standalone Raspberry Pi 4/5 loopstation (DIY / THT)

An **alternative main board** that turns the loopy foot-pedal into a *self-contained
appliance*: the board **stacks on top of a Raspberry Pi 4 / Pi 5 as an oversized HAT**
(40-pin GPIO socket on the underside — see §9), and the Pi **runs the loopy audio engine**
— no host computer. Audio I/O comes from a **USB audio interface** plugged into the Pi.
The board carries everything else:

- **Pedalboard power** — one 9 V DC barrel jack → 5 V buck → feeds the Pi over GPIO.
- **Control I/O** — 10 footswitches + EC11 encoder read directly on Pi GPIO.
- **Indicators** — two WS2812 strips (7-LED indicator + 12-LED ring), 3.3 V→5 V buffered.

**Every part is through-hole / hand-solderable** — TO-220 regulator + FET, a DIP-20
buffer, axial resistors, disc & radial-electrolytic caps, leaded diodes, a 3 mm LED.
The connectors (GPIO socket, JST, barrel, pin headers) are through-hole anyway. No
fine-pitch SMD, no hot-air needed — buildable with a basic iron.

> **What this is *not*:** the original [`loopy_pedal_pcb_design.md`](loopy_pedal_pcb_design.md)
> is a **MIDI controller** (ATmega328P + ATmega16U2 USB-MIDI) that talks to loopy on a
> PC. This board **deletes both ATmegas, the USB-device section, and all MIDI** — the Pi
> *is* the computer and reads the footswitches directly over GPIO. USB-MIDI controllers
> still work via the Pi's USB ports in software. The control front-end (footswitches,
> encoder, WS2812 strips) is preserved so the **existing ring board mates unchanged**
> (same 8-pin pinout, §7).

---

## 1. System architecture

```
  9V DC ─▶ rev-prot P-FET ─▶ LM2596 BUCK 5V(3A) ─┬─▶ +5V ─▶ GPIO 5V (pins 2,4)  ┐
          (IRF9540N + TVS)   (+ 1N5822 + 33µH L)  │                              │  Raspberry
          [J_5V_AUX bypass-in ──────────────────┘                               ├▶ Pi 4 / Pi 5
                                                                                 │  (runs loopy)
  Pi 3V3 (pins 1,17) ◀── used on-board for the I2C header                        ┘

  CONTROL (all on the 40-pin header, §3)
    GPIO ─ 10× footswitch (active-low, Pi pull-ups, RC debounce) ── 10× JST-XH
    GPIO18(PWM0) ─▶ 74HCT244 ─330Ω─▶ indicator strip (7 WS2812)    ── J_IND  (3-pin)
    GPIO13(PWM1) ─▶ 74HCT244 ─330Ω─▶ ring strip (12 WS2812)        ─┐
    GPIO5/6/16   ─ EC11 A / B / SW ────────────────────────────────  ├ J_RING (8-pin = old ring board)
    GPIO2/3      ─ I2C SDA/SCL (optional status OLED)              ── J_I2C  (4-pin)
    GPIO19       ─ panel power/▶shutdown button                    ── J_PWR_BTN (2-pin)
```

- **One supply rail.** There is no USB-device power path here — the single buck rail
  powers the Pi *and* the WS2812 buffer.
- **Single common ground.**
- **USB-MIDI** (class-compliant controllers, or loopy's own foot-controller protocol)
  is handled **in software on the Pi**.

---

## 2. Power subsystem (all THT)

**Input:** 2.1 mm barrel jack, **center-positive** (silkscreen it — pedal "9 V" is often
center-negative). A bidirectional **TVS** (P6KE15CA, DO-15) clamps transients; a high-side
**P-MOSFET** (**IRF9540N**, TO-220, −100 V/−23 A) gives lossless reverse-polarity
protection (body diode conducts input→load, blocks on reversed polarity). 100 kΩ gate
pull-down turns it on; a 12 V Zener clamps Vgs.

**Buck (9 V→5 V):** **LM2596T-5** — the ubiquitous DIY TO-220 switcher, fixed 5.0 V, 3 A,
150 kHz. Non-synchronous, so the classic external circuit: 100 µF input electrolytic,
**1N5822** Schottky catch diode (DO-201AD), **33 µH** radial inductor, 680 µF output
electrolytic. ON/OFF pin grounded (enabled); Feedback pin tied to the +5 V output (fixed
version). Everything is leaded and solderable with a basic iron.

**Why 5 V over GPIO:** feeding the Pi through the 5 V GPIO pins lets the whole appliance
run from a single pedalboard 9 V jack. Build-time caveats (not board-affecting):

- **Pi 5** powered via GPIO bypasses PD negotiation, so firmware defaults to limiting
  *downstream USB* to ~600 mA — a bus-powered USB audio interface fits under that.
- Feeding GPIO bypasses the Pi's onboard input protection — the board provides its own
  (TVS + reverse-prot FET + the buck's current limit).

### Power budget — the 3 A reality

| rail | load | current |
|------|------|---------|
| +5V (Pi) | Pi Zero 2 / Pi 3 / Pi 4, typical loopstation load | ~1.5 – 2.8 A |
| +5V (LEDs) | 19× WS2812B, **firmware-capped** brightness | ~0.3 – 0.5 A |
| **+5V total** | | **≤ 3 A** (≈ 2.3 A on the 9 V side @ ~88 %) |

The only THT switching regulators in the KiCad library top out at **3 A** (LM2576/LM2596).
That comfortably runs a **Pi Zero 2 / Pi 3 / Pi 4** under a typical loopstation workload
**with the WS2812 global brightness capped in firmware** (the loop indicators never need
full white — cap to ~0.4 A via `FastLED.setMaxPowerInVoltsAndMilliamps(5, 400)` or a
brightness ceiling). A **Pi 5** under heavy CPU + USB load can exceed 3 A — for that,
**bypass the buck**: don't populate U1 and feed regulated 5 V/≥5 A into **J_5V_AUX** (2-pin,
on +5V/GND). The two inputs are mutually exclusive by build config — no ORing hardware.

Size the barrel jack, inductor, and +5V/GND copper for **≥ 3 A**; a **1000 µF** bulk
electrolytic + 4× 100 nF disc across +5V at the GPIO header handle Pi inrush.

---

## 3. Raspberry Pi 40-pin GPIO assignment

The board takes a **2×20 2.54 mm female socket** (`PinSocket_2x20_P2.54mm_Vertical`) that
mates to the Pi's GPIO header (§9). It uses the `Connector:Raspberry_Pi_4` symbol so every
pin is explicit and ERC-checked. BCM:

| Function | BCM | hdr | | Function | BCM | hdr |
|----------|-----|-----|---|----------|-----|-----|
| Footsw RECPLAY | GPIO4 | 7 | | Footsw CLEAR | GPIO20 | 38 |
| Footsw STOP | GPIO17 | 11 | | Footsw BANK | GPIO21 | 40 |
| Footsw UNDO | GPIO27 | 13 | | Encoder A | GPIO5 | 29 |
| Footsw MODE | GPIO22 | 15 | | Encoder B | GPIO6 | 31 |
| Footsw TRACK1 | GPIO23 | 16 | | Encoder SW | GPIO16 | 36 |
| Footsw TRACK2 | GPIO24 | 18 | | **Indicator LED** | **GPIO18/PWM0** | 12 |
| Footsw TRACK3 | GPIO25 | 22 | | **Ring LED** | **GPIO13/PWM1** | 33 |
| Footsw TRACK4 | GPIO12 | 32 | | Power button | GPIO19 | 35 |
| I2C SDA | GPIO2 | 3 | | I2C SCL | GPIO3 | 5 |
| +5V feed | 5V | 2, 4 | | 3V3 (from Pi) | 3V3 | 1, 17 |
| GND | GND | 6,9,14,20,25,30,34,39 | | | | |

- **Footswitches + encoder** use the Pi's **internal pull-ups** (active-low; LOW =
  pressed), with hardware RC debounce.
- **WS2812 strips on PWM0 (GPIO18) + PWM1 (GPIO13)** — the dual-channel combo the
  `rpi_ws281x` DMA driver supports.
- **GPIO14/15 (the old UART MIDI) and SPI0 (GPIO7–11) are left free** for expansion.

The footswitch **note map** (RECPLAY=0 … BANK=9) is unchanged, so loopy's existing mapping
is the single source of truth.

---

## 4. WS2812 LED outputs — 3.3 V → 5 V level-shifted

The Pi GPIO is **3.3 V**, below the WS2812 5 V logic-HIGH threshold. Both data lines pass
through one **74HCT244** octal buffer (DIP-20) powered at 5 V: its TTL inputs accept 3.3 V
as a valid HIGH and the outputs swing 0–5 V — so it **buffers and level-shifts**. **330 Ω**
series after each buffer; **1000 µF** bulk + 100 nF/4-LEDs at each strip's first LED (off
board). The 74HCT244 is the canonical DIY WS2812 level-shifter — one cheap DIP does both
channels (group 1: 1A0→1Y0 indicator, 1A1→1Y1 ring; group 2 disabled).

- **Indicator strip** — GPIO18 → buffer → **J_IND** (3-pin: +5V / data / GND), 7 LEDs.
- **Ring strip** — GPIO13 → buffer → **J_RING** pin 5, 12 LEDs on the ring board.

Each strip is its own chain indexed from 0 — identical to the original two-strip scheme,
so the firmware's `indicatorLeds[7]` / `ringLeds[12]` split carries over verbatim.

---

## 5. Footswitch inputs

10 momentary SPST foot switches on **ten 2-pin JST-XH headers** (pin 1 = signal, pin 2 =
GND), laid out in a centred 5×2 grid, each **silk-labelled with its pedal function**. Per
switch: **100 nF** disc cap across the switch pin→GND for hardware RC debounce, belt-and-
suspenders with the firmware debounce. Mapping:

| ref | pedal | ref | pedal |
|-----|-------|-----|-------|
| J3 | RECPLAY | J8 | TRACK2 |
| J4 | STOP | J9 | TRACK3 |
| J5 | UNDO | J10 | TRACK4 |
| J6 | MODE | J11 | CLEAR |
| J7 | TRACK1 | J12 | BANK |

---

## 6. I²C / power-button / aux headers

- **J_I2C** (4-pin: 3V3 / SDA / SCL / GND) — optional status OLED or expansion; the Pi's
  onboard 1.8 kΩ I²C pull-ups serve, so no extra pull-ups here.
- **J_PWR_BTN** (2-pin: GPIO19 / GND) — panel momentary for a clean software shutdown
  (`gpio-shutdown` overlay).
- **J_5V_AUX** (2-pin: +5V / GND) — external 5 V bypass input when U1 (buck) is left
  unpopulated (§2); also a bench-supply / current-probe point.
- **Power-good LED** (D4 + 1 kΩ) on +5V.

---

## 7. Ring board (reused unchanged)

The existing ring board ([`loopy_pedal_ring.kicad_pcb`](kicad/loopy_pedal_ring.kicad_pcb))
mates to **J_RING** with the **identical 8-pin pinout**, so it is reused as-is:

| pin | net | | pin | net |
|-----|-----|---|-----|-----|
| 1 | +5V | | 5 | RING_DATA (from GPIO13 via 74HCT244 + 330 Ω) |
| 2 | +5V | | 6 | ENC_A |
| 3 | GND | | 7 | ENC_B |
| 4 | GND | | 8 | ENC_SW |

12× WS2812B ring + EC11 encoder live on that board; keep the cable ≤ ~30 cm.

---

## 8. Bill of materials (key parts, main board) — all THT

| ref | part | pkg | qty |
|-----|------|-----|-----|
| J1 | Raspberry Pi 40-pin GPIO **socket** (2×20, 2.54 mm) | PinSocket_2x20 | 1 |
| U1 | **LM2596T-5** 3 A buck (fixed 5 V) | TO-220-5 | 1 |
| U2 | **74HCT244** octal buffer / WS2812 level-shift | DIP-20 | 1 |
| Q1 | **IRF9540N** reverse-prot P-FET | TO-220 | 1 |
| L1 | 33 µH ≥3 A radial inductor | D12 radial | 1 |
| D1 | P6KE15CA TVS | DO-15 | 1 |
| D2 | 12 V Zener (gate clamp) | DO-35 | 1 |
| D3 | **1N5822** Schottky catch diode | DO-201AD | 1 |
| D4 | power-good LED | 3 mm | 1 |
| J2 | 2.1 mm barrel jack (center +) | — | 1 |
| J3–J12 | footswitch headers (2-pin) | JST-XH B2B-XH-A | 10 |
| J13 | ring-board header (8-pin) | JST-XH | 1 |
| J14 | indicator-LED breakout (3-pin) | JST-XH | 1 |
| J17 | I²C header (4-pin) | 2.54 header | 1 |
| J18 | power button (2-pin) | 2.54 header | 1 |
| J19 | 5 V aux/bypass (2-pin) | 2.54 header | 1 |
| R1 | 100 kΩ gate pull-down | axial | 1 |
| R2,R3 | 330 Ω WS2812 series | axial | 2 |
| R4 | 1 kΩ LED series | axial | 1 |
| C1 | 100 µF input electrolytic | radial | 1 |
| C3 | 680 µF output electrolytic | radial | 1 |
| C5 | 1000 µF +5V bulk | radial | 1 |
| C2,C4,C6–C11 | 100 nF disc (decoupling) | disc | 8 |
| C12–C21 | 100 nF disc (footswitch debounce) | disc | 10 |

10× foot switches, the ring board, a USB audio interface, and the 9 V PSU are external.

---

## 9. Layout & mounting

- **Board:** **96 × 98 mm** (under 100 × 100 → cheapest fab tier), 2-layer, 1.6 mm. Bottom
  = GND pour, top = signals + power + a GND pour; GND stitching vias tie the planes.
- **Oversized HAT (board on top of the Pi).** It carries the full **Raspberry Pi HAT
  mounting pattern — 4× M2.5 on a 58 × 49 mm rectangle**, centred on the GPIO socket, so it
  bolts to the Pi's standoffs. The board sits **on top of the Pi, components facing up**;
  the **2×20 female socket is on the *bottom* copper layer** (J1 is flipped to B.Cu), facing
  down onto the Pi's male header. Mounting the socket from the underside mirrors the pad
  pattern left-right — that mirror is what makes pin 1 land on the Pi's pin 1 when stacked,
  and is exactly what the bottom-layer placement does. *Verify the socket↔hole offset
  against your Pi's mechanical drawing before ordering.*
- **Clearance / standoffs.** The board (96 × 98) overhangs the Pi (85 × 56), so its
  underside passes over the Pi 4's ~17 mm USB-A / Ethernet stack. Use **≥20 mm standoffs**
  *and* an extended / stacking GPIO header (tall pins) to bridge that gap — a plain
  11 mm-tall socket would foul those connectors. The bottom mounting-hole row is also why
  the power section sits in the lower third: it keeps those two drills clear of parts.
- **Top edge:** the 2×20 GPIO socket footprint (mounted underneath), with the +5V
  decoupling discs just below it. All other components are top-side.
- **Power section** is the bottom band, signal-flow ordered: barrel → reverse-prot FET →
  LM2596 → catch diode → inductor → output caps → bulk. Wide +5V/GND copper to the GPIO
  5V pins; keep the SW node (between U1, D3, L1) compact.
- **External I/O on edges:** 9 V barrel on the bottom edge; ring / indicator / I²C /
  buttons interconnect row under the GPIO header; footswitch 5×2 grid in the middle.

**Manufacturing:** 2-layer, 1.6 mm, HASL, JLCPCB/PCBWay-friendly. **Everything is
hand-solderable through-hole** — no SMD, no stencil, no hot-air.

---

## 10. KiCad files (generated + verified)

Same scripted SKiDL → KiCad 10 → Freerouting pipeline as the original board.

| file | what |
|------|------|
| `kicad/pi_main_board.py` | SKiDL source → `pi_main_board.net`, ERC-verified (0 errors) |
| `kicad/pi_main_board.net` | KiCad netlist, importable into pcbnew |
| `kicad/loopy_pi_main.kicad_pcb` (+ `.kicad_pro`) | placed, routed, **DRC 0 / 0 unrouted** |
| `kicad/fab/loopy_pi_main/` + `…_gerbers.zip` | Gerbers + Excellon drill |

50 parts, **96 × 98 mm**, 2-layer, ~400 track segments, GND pours both layers +
stitching vias, **0 DRC errors / 0 unrouted**, all through-hole.

### Regenerate
```sh
set KICAD8_SYMBOL_DIR=C:\Program Files\KiCad\10.0\share\kicad\symbols
python hardware/kicad/pi_main_board.py            # -> pi_main_board.net + .erc

# board (KiCad-bundled python has pcbnew):
KP="C:\Program Files\KiCad\10.0\bin\python.exe"
"$KP" hardware/kicad/_pi_net2board.py             # netlist -> board
"$KP" hardware/kicad/_pi_place.py                 # functional placement + holes + keepouts
"$KP" hardware/kicad/_pi_dsn.py 0.25              # export Specctra DSN
java -jar hardware/kicad/_tools/freerouting-1.6.5.jar -de loopy_pi_main.dsn -do loopy_pi_main.ses -mp 100
"$KP" hardware/kicad/_pi_finalize.py              # import SES + GND pours + stitching
kicad-cli pcb drc loopy_pi_main.kicad_pcb
kicad-cli pcb export gerbers -o fab/loopy_pi_main/ loopy_pi_main.kicad_pcb
kicad-cli pcb export drill   -o fab/loopy_pi_main/ loopy_pi_main.kicad_pcb
```
(The `_pi_*.py` helpers are local-path pipeline tooling, gitignored like the original
board's `_pcb_*.py` scripts.)

### Seeing the Pi in 3D (board mounted on a Pi)

The board carries the Pi 4 + four standoffs as **board-only 3D models** (added by
`kicad/pi_mating_model.py`), so opening `loopy_pi_main.kicad_pcb` and pressing
**Alt-3** shows the mounted stack directly. These footprints have no pads / silk /
courtyard and are excluded from BOM, position files and the netlist — Gerbers,
drill and DRC are byte-for-byte unaffected (verified). The standoffs come from
KiCad's bundled Würth library; the Pi model is referenced as
`${KIPRJMOD}/_models/RPi4.step` and is **downloaded on demand** (~17 MB, from the
community [MGS-CAD-Files](https://github.com/multigamesystem/MGS-CAD-Files) repo)
by `pi_assemble.py` — gitignored, not redistributed, so a fresh clone shows a
missing-model placeholder until you fetch it:

```sh
KP="C:\Program Files\KiCad\10.0\bin\python.exe"
"$KP" hardware/kicad/pi_assemble.py       # downloads the Pi model into _models/
"$KP" hardware/kicad/pi_mating_model.py   # (re)attach the board-only Pi+standoffs
```

`pi_assemble.py` also builds a standalone `_assembly.kicad_pcb` (gitignored) if you
want an isolated render. Render-only: the Pi/standoff alignment is approximate
(visual, not a fit-check).
