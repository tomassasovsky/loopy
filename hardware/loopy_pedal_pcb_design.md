# Loopy foot-pedal — PCB design (standalone, 2 boards)

A custom **standalone** controller board (onboard ATmega328P + ATmega16U2 USB-MIDI,
replacing the Arduino UNO) plus a **ring board** (12-LED loop ring + rotary encoder).
The 328P runs the `firmware/loopy_pedal` thin-client sketch; the 16U2 runs
dualMocoLUFA to present USB-MIDI. Powered from a 9 V DC barrel jack through an
onboard 5 V buck, with USB providing 5 V to the logic when no 9 V is present.

> The 328P + 16U2 + USB section is a near-verbatim lift of the **open-source
> Arduino UNO R3 reference schematic** (proven). The pedal-specific additions are:
> the 9 V→5 V **buck**, the **footswitch inputs** (with hardware RC debounce), the
> **WS2812 LED chain** split across two boards, and the **encoder**. Reusing the UNO
> USB section means the firmware/flashing flow you already have keeps working.

---

## 1. System architecture

```
  9V DC ─▶ rev-prot ─▶ BUCK 5V(3A) ─┬──────────────────────────▶ 5V_LED (both LED strips)
                                     └──[ideal-diode OR]──┐
  USB-C 5V ──────────────[ideal-diode OR]────────────────┴─────▶ 5V_LOGIC (328P + 16U2)

  MIDI  | USB-C D+/D- ▶ 16U2 (dualMoco USB-MIDI)  TXD ─┐
        |                                              ├─[74HC08 AND merge]─▶ 328P RXD
        | DIN MIDI IN ▶ H11L1 opto ────────────────────┘
        | 328P TXD ─┬─▶ 16U2 RXD (USB out)
        |           └─▶ 74AHCT125 buf ─▶ DIN MIDI OUT
        | (same 31250 UART → USB and DIN carry the identical pedal protocol)

  I/O   | 328P ─ D3..D12 ──▶ 10× footswitches (RC debounce, connectors)
        |      ─ D2 ───────▶ indicator strip: 7× WS2812 (main board, idx 0..6)
        |      ─ A3 ──┐
        |      ─ A0/A1/A2 (encoder) ──┐
        |              └─ 8-pin cable ─▶ RING BOARD: 12× WS2812 ring (A3 data) + EC11
```

- **Logic (328P + 16U2)** runs from `5V_LOGIC` = OR(USB 5 V, buck 5 V) → works on
  USB alone (flashing / USB-MIDI) **or** on 9 V (DIN-MIDI / standalone).
- **LEDs** (both strips) run from `5V_LED` = **buck only**. Without the 9 V supply the
  LEDs stay dark (they'd exceed a USB port); logic + MIDI still work on USB alone.
- **MIDI** is available over **USB and DIN at once** (output) / either source
  (input, §6), so the pedal works plugged into a computer *or* an interface's MIDI.
- Single common ground (the DIN **IN** is opto-isolated to break ground loops).

---

## 2. LED outputs — two independent WS2812 strips

The 328P drives **two separate WS2812 data lines**, one per board, so the boards
are independent and the inter-board cable carries a **single data line with no
return**:

- **Indicator strip** — **D2 (PD2)**, **7 LEDs on the main board**, indices 0–6:

  | index | role |
  |-------|------|
  | 0 | Mode |
  | 1–4 | Track 1–4 |
  | 5 | Clear |
  | 6 | Bank |

- **Ring strip** — **A3 (PC3)**, **12 LEDs on the ring board**, indices 0–11, fed
  over the cable.

Each strip is its own chain indexed from 0 — **no cross-board chaining, no data
return, no index reordering**.

> **Firmware:** drive two controllers/arrays instead of one:
> ```cpp
> FastLED.addLeds<WS2812B, 2,  GRB>(indicatorLeds, 7);  // D2, on the main board
> FastLED.addLeds<WS2812B, A3, GRB>(ringLeds, 12);      // A3 -> cable -> ring
> ```
> One `FastLED.show()` updates both. Split the current `g_leds[19]` into
> `indicatorLeds[7]` (mode / tracks / clear / bank) + `ringLeds[12]`, each indexed
> from 0. (No chain re-ordering needed — simpler than the single-chain plan.)

Data integrity: **330 Ω** series at each data pin; a **74AHCT125** buffer on the
**ring** data line **before the cable** (clean 5 V over the ribbon); **1000 µF**
bulk across `5V_LED` at each board's first LED + a 100 nF per ~4 LEDs.

---

## 3. Power subsystem (main board)

**Input:** 2.1 mm barrel jack, **center-positive** (label clearly; pedal "9 V" is
often center-negative — pick one and silkscreen it). Add a **TVS** (SMBJ12A) and a
**reverse-polarity P-MOSFET** (e.g., DMP3098L: source→jack+, drain→VIN, gate→GND)
across the input.

**Buck (9 V→5 V):** **MP1584EN** (SOT-23-8) or **MP2315** (3 A) switching regulator,
set to 5.0 V. Reference MP1584 application circuit: 10 µH inductor, SS36 catch diode
(if not synchronous), 22 µF in / 2× 22 µF out, FB divider for 5.0 V. Budget below
needs ~1.4 A peak, so a 3 A part runs cool.

**5 V OR-ing:** two **LM66100** ideal-diode controllers (or P-FET ORing) combine
USB 5 V and buck 5 V into `5V_LOGIC`. `5V_LED` taps the **buck output only**.

### Power budget (worst case, all LEDs full white)

| rail | load | current |
|------|------|---------|
| 5V_LED | 19 × WS2812B @ 60 mA | 1.14 A |
| 5V_LOGIC | 328P + 16U2 + USB | ~0.07 A |
| **total @ 5 V** | | **~1.2 A** (→ ~0.75 A from 9 V through the buck @ ~88 %) |

Real-world (a few LEDs lit, breathing) is far lower; size for the 1.2 A worst case.
Barrel jack / buck inductor / cable conductors rated ≥ 2 A.

---

## 4. MCU subsystem — ATmega328P-AU (TQFP-32)

Lifted from the UNO R3 "main MCU" block:

- **Clock:** 16 MHz crystal on XTAL1/XTAL2 (pins 7/8) + 2× 22 pF to GND.
- **Reset:** 10 kΩ from RESET (pin 29) to 5V_LOGIC; reset tact switch to GND;
  **100 nF** from the 16U2's DTR line to RESET (auto-reset on sketch upload).
- **Decoupling:** 100 nF on each VCC (pins 4, 6); 100 nF + 10 µF bulk; **AVCC**
  (pin 18) via a 10 µH ferrite/inductor from 5 V + 100 nF; AREF 100 nF.
- **ICSP-328P:** 2×3 header (MISO/MOSI/SCK/RESET/VCC/GND) for bootloader burning.

### 328P pin assignment (matches the firmware)

| Port / pin | Arduino | Net | Use |
|------------|---------|-----|-----|
| PD0 (RXD) | D0 | UART_RX ← 16U2 TXD | serial MIDI in (31250) |
| PD1 (TXD) | D1 | UART_TX → 16U2 RXD | serial MIDI out (31250) |
| **PD2** | **D2** | **IND_DATA** | indicator-LED strip (7), main board, 330 Ω series |
| PD3 | D3 | SW_RECPLAY | footswitch (note 0) |
| PD4 | D4 | SW_STOP | footswitch (note 1) |
| PD5 | D5 | SW_UNDO | footswitch (note 2) |
| PD6 | D6 | SW_MODE | footswitch (note 3) |
| PD7 | D7 | SW_TRACK1 | footswitch (note 4) |
| PB0 | D8 | SW_TRACK2 | footswitch (note 5) |
| PB1 | D9 | SW_TRACK3 | footswitch (note 6) |
| PB2 | D10 | SW_TRACK4 | footswitch (note 7) |
| PB3 | D11 | SW_CLEAR | footswitch (note 8) |
| PB4 | D12 | SW_BANK | footswitch (note 9) |
| PC0 | A0 | ENC_A | encoder clock |
| PC1 | A1 | ENC_B | encoder data |
| PC2 | A2 | ENC_SW | encoder push (reserved) |
| **PC3** | **A3** | **RING_DATA** | ring-LED strip (12) → 74AHCT125 → cable |
| PB5 | D13 | (ICSP SCK) | — (free; onboard "alive" LED optional) |

All footswitch + encoder inputs use the 328P **internal pull-ups** (active-low);
external hardware debounce below complements the firmware's 25 ms debounce.

---

## 5. USB-MIDI subsystem — ATmega16U2-AU (TQFP-32)

Verbatim from the UNO R3 "USB interface" block:

- **USB-C** receptacle (USB 2.0): VBUS→USB 5 V, D+/D− through **22 Ω** series each to
  the 16U2 D+/D− (pins 4/3 on the 16U2 are the differential pair per the UNO ref;
  use the symbol's UDP/UDM), **CC1/CC2 → 5.1 kΩ** to GND (advertise UFP/device).
- **Clock:** 16 MHz crystal + 2× 22 pF.
- **16U2 ↔ 328P (shared UART):** 16U2 PD3(RXD) ← 328P TXD (output to USB **and** the
  DIN MIDI OUT in parallel); 328P RXD ← the **MIDI-IN merge** (§6), one input of
  which is 16U2 PD2(TXD). 16U2 PD7 → the 100 nF → 328P RESET (DTR auto-reset). Test
  pads/jumper for the dualMoco **MOSI/PB2 → GND** "serial mode" select.
- **ESD:** USBLC6-2SC6 on D+/D−/VBUS.
- **ICSP-16U2:** 2×3 header (for DFU recovery / dualMoco flashing).
- **RESET-16U2:** tact switch + 10 kΩ pull-up (the DFU-entry RESET+GND we used).

---

## 6. Hardware MIDI (5-pin DIN) — standalone / interface mode

So the pedal can run on **9 V only** (no computer) and talk to an audio
interface's MIDI ports, the main board also exposes opto-isolated **DIN-5 MIDI IN**
and a buffered **DIN-5 MIDI OUT**. It's the **same 31250-baud UART** the 16U2
bridges to USB — so USB-MIDI and DIN-MIDI carry the identical pedal protocol, and
**no firmware change** is needed. In this mode loopy simply selects the
*interface's* MIDI in/out instead of "MocoLUFA".

```
328P TXD ──┬──▶ 16U2 RXD            (USB-MIDI out)
           └──▶ 74AHCT125 buf ─220Ω─▶ DIN-OUT pin 5   (+5V─220Ω─▶ pin 4, pin 2─GND)

DIN-IN ─▶ H11L1 opto ─┐
                      ├─[74HC08 AND]──▶ 328P RXD       (MIDI-IN merge)
16U2 TXD ─────────────┘                                (USB-MIDI in)
```

- **MIDI OUT** (not isolated, per spec): 328P TXD → one spare **74AHCT125** buffer →
  220 Ω → DIN pin 5; +5 V → 220 Ω → DIN pin 4; pin 2 → GND. Drives USB and DIN at
  once (harmless when one side is unused).
- **MIDI IN** (isolated): DIN pin 4 → 220 Ω → **H11L1** opto input; pin 5 → opto
  cathode; 1N4148 reverse-protection across the input. The opto's logic output is
  one input of the merge.
- **MIDI-IN merge:** a single **74HC08** AND gate combines `16U2 TXD` and the opto
  output into `328P RXD`. Both idle HIGH; whichever source transmits pulls RXD —
  so USB-in and DIN-in both work with no switch. *Caveat:* don't drive **both**
  inputs simultaneously (two async streams collide); use one source at a time.
  (A SPDT "USB/DIN" slide switch on RXD is the simpler alternative if you prefer.)
- **Connectors:** 2× panel **DIN-5** (180°) jacks, or 2× **3.5 mm TRS (MIDI Type-A)**
  for a compact build — wire pins 4/5/2 to TRS tip/ring/sleeve per Type-A.
- The H11L1 needs no negative supply and includes a Schmitt output (fewer parts
  than a 6N138).

---

## 7. Footswitch inputs (main board)

10 momentary SPST foot switches (panel-mounted, wired to the board). Per switch:

- Switch between the MCU pin and **GND** (active-low; internal pull-up on).
- **100 nF** across the switch (pin→GND) for hardware RC debounce (~few ms with the
  internal pull-up) — belt-and-suspenders with the firmware's 25 ms debounce.
- Optional **100 Ω** series + **TVS/ESD** if the switch wiring is long.

**Connectors:** two 6-pin (or one 12-pin) **screw terminals** or **JST-XH**: 10
switch signals + 2 GND returns. Label each on the silkscreen by function.

---

## 8. Ring board

- **12× WS2812B** in a circle (loop ring), chain indices 7–18, DIN from the cable,
  DOUT unused (end of chain). 100 nF per ~4 LEDs + **1000 µF** bulk across 5 V at DIN.
- **EC11 rotary encoder** (with push switch): A→ENC_A, B→ENC_B, C(common)→GND,
  switch→ENC_SW + GND. Add **10 kΩ pull-ups + 100 nF** RC on A/B (encoders bounce).
- **Inter-board connector** (8-pin JST-XH, see §9).
- Center cutout / mount for the encoder shaft; ring LED pitch sized to the enclosure.

---

## 9. Inter-board connector (main ↔ ring), 8-pin JST-XH

| pin | net | notes |
|-----|-----|-------|
| 1 | 5V_LED | LED power (doubled for current) |
| 2 | 5V_LED | " |
| 3 | GND | doubled |
| 4 | GND | " |
| 5 | RING_DATA | from A3 via 74AHCT125, to ring DIN (LED 0) |
| 6 | ENC_A | |
| 7 | ENC_B | |
| 8 | ENC_SW | |

Keep the cable ≤ ~30 cm; the 74AHCT125 buffer + doubled power pins handle the run.

---

## 10. Bill of materials (key parts)

**Main board**

| ref | part | pkg | qty |
|-----|------|-----|-----|
| U1 | ATmega328P-AU | TQFP-32 | 1 |
| U2 | ATmega16U2-AU | TQFP-32 | 1 |
| U3 | MP1584EN (or MP2315) buck | SOT-23-8 | 1 |
| U4 | 74AHCT125 (ring-data + MIDI-OUT buffers) | SOIC-14 | 1 |
| U5,U6 | LM66100 ideal diode | SOT-23-5 | 2 |
| U7 | USBLC6-2SC6 ESD | SOT-23-6 | 1 |
| U8 | H11L1 MIDI-IN opto-isolator | DIP-6/SMD | 1 |
| U9 | 74HC08 (MIDI-IN AND merge) | SOIC-14 | 1 |
| Y1,Y2 | 16 MHz crystal | HC-49/SMD | 2 |
| J1 | USB-C receptacle (2.0) | — | 1 |
| J2 | 2.1 mm barrel jack | — | 1 |
| J3,J4 | footswitch terminals (6-pos) | JST-XH/screw | 2 |
| J5 | ring-board header (8-pin) | JST-XH | 1 |
| J6,J7 | ICSP (2×3) | 2.54 hdr | 2 |
| J8,J9 | MIDI IN / OUT (DIN-5 180°, or 3.5 mm TRS-A) | — | 2 |
| Q1 | DMP3098L reverse-prot P-FET | SOT-23 | 1 |
| L1 | 10 µH ≥2 A buck inductor | — | 1 |
| D1 | SS36 (if non-sync buck) | SMA | 1 |
| D2 | 1N4148 (MIDI-IN protection) | SOD-123 | 1 |
| — | R/C: 22 pF×4, 100 nF×~13, 10 µF, 22 µF×3, 1000 µF, 10 kΩ×~4, 22 Ω×2, 5.1 kΩ×2, 330 Ω, 220 Ω×3 (MIDI), 100 nF debounce×10 | 0603 | — |
| SW1,SW2 | reset tact (328P, 16U2) | — | 2 |
| — | indicator LEDs WS2812B (chain 0–6) | 5050 | 7 |

**Ring board**

| ref | part | qty |
|-----|------|-----|
| D7–D18 | WS2812B | 12 |
| ENC1 | EC11 rotary encoder + switch | 1 |
| J1 | 8-pin header | 1 |
| — | 1000 µF, 100 nF×4, 10 kΩ×2, 100 nF×2 (enc RC) | — |

10× foot switches and the barrel-jack PSU are external.

---

## 11. Layout & routing guidance (2-layer, both boards)

- **Stackup:** 2-layer is sufficient; bottom = ground pour, top = signals + power.
- **Buck:** tight input loop (Cin–VIN–GND), keep the SW node small, inductor close,
  output cap near the IC; star/wide ground; keep the switch node away from the
  crystals and USB pair.
- **USB:** route **D+/D− as a ~90 Ω differential pair**, short, matched, over a solid
  ground plane; series 22 Ω near the 16U2; ESD diode at the connector.
- **Crystals:** each crystal + its 22 pF tight to the MCU, guard ground around, no
  fast signals underneath.
- **Decoupling:** a 100 nF right at every VCC pin.
- **LED power:** wide 5V_LED/GND pours (≥ 1.2 A); bulk cap at each board's first LED.
- **Footswitch + encoder lines:** keep RC caps near the connector/MCU; ground-guard
  the encoder lines.
- **Mounting:** 4× M3 holes per board; align the ring board's encoder + LED pitch to
  the enclosure faceplate.

**Manufacturing:** 2-layer, 1.6 mm, HASL/ENIG, JLCPCB/PCBWay-friendly. The 328P/16U2
TQFP-32 and SOT-23 parts are hand-solderable with a fine tip + flux, or use a stencil.

---

## 12. KiCad files (generated + verified)

The netlists for both boards are **generated by SKiDL scripts** in `hardware/kicad/`
and **ERC-verified against the KiCad 10 libraries** (pins read from the real
symbols, so no hand-transcription errors):

| file | what |
|------|------|
| `kicad/main_board.py` | SKiDL source for the main board → `main_board.net` (84 parts) |
| `kicad/ring_board.py` | SKiDL source for the ring board → `ring_board.net` (22 parts) |
| `kicad/main_board.net`, `ring_board.net` | KiCad netlists, importable into pcbnew |

Verified here: **main board — 0 ERC errors** (30 warnings, all expected
unconnected pins: unused MCU GPIOs, USB-C sideband, DIN unused pins, chain-end
DOUT); **ring board — 0 ERC errors**. Both netlists generate with 0 errors.

KiCad-10 symbol names actually used (these differ from older libs): the MCUs are
`MCU_Microchip_ATmega:ATmega328P-A` and `…:ATmega16U2-A`; the buck is
`Regulator_Switching:AP63203WU` (synchronous — no catch diode); the ideal diodes
are `Power_Management:LM66100DCK`; logic is single-gate `74xGxx:74AHCT1G125`
(×2 buffers) and `74xGxx:74AHCT1G08` (merge); USB-C is
`Connector:USB_C_Receptacle_USB2.0_16P`; encoder `Device:RotaryEncoder_Switch`.

### Regenerate the netlists
```sh
set KICAD8_SYMBOL_DIR=C:\Program Files\KiCad\10.0\share\kicad\symbols
python hardware/kicad/main_board.py   # -> main_board.net + main_board.erc
python hardware/kicad/ring_board.py   # -> ring_board.net + ring_board.erc
```

### Laid-out, routed boards (committed)

Both boards are **placed, routed, and DRC-clean** (KiCad 10.0.3):

| file | what |
|------|------|
| `kicad/loopy_pedal_main.kicad_pcb` (+ `.kicad_pro`) | main board: 82×66 mm, 72 parts, 2-layer, **DRC 0 errors / 0 unrouted** |
| `kicad/loopy_pedal_ring.kicad_pcb` (+ `.kicad_pro`) | ring board: ⌀68 mm round, 22 parts, 12-LED ring + center encoder, **287 segs / 4 vias, DRC 0 / 0 unrouted** |
| `kicad/fab/loopy_pedal_main_gerbers.zip` | main board Gerbers + Excellon drill |
| `kicad/fab/loopy_pedal_ring_gerbers.zip` | ring board Gerbers + Excellon drill |

Both have GND copper pours on F.Cu and B.Cu, four M3 (main) / three M2 (ring)
mounting holes. Default clearance is **0.15 mm** (to clear the USB-C connector's
inherent fine pitch); everything else routes at 0.2 mm. Q1 reverse-protection
FET is **`Transistor_FET:AO3401A`** (numbered pads that match SOT-23 — the
generic `Q_PMOS` letter-pads do not).

**I/O layout:** all external I/O is on the **bottom edge** — 9 V barrel, USB-C,
and the two MIDI jacks — each aligned to the board boundary so the openings
overhang ~1.5–2 mm and stay reachable from outside the enclosure. Internal
interconnects sit elsewhere: ring + indicator breakout on the top edge,
footswitch headers on the left edge.

**MIDI jacks (J8/J9)** are real **right-angle shielded 5-pin DIN sockets**
(SparkFun/Tayda style) — footprint `loopy:MIDI_DIN5_RA` in the local
`kicad/loopy.pretty/` library (KiCad has no stock 5-pin DIN). The pad pattern is
the genuine right-angle landing pattern (pins 1/2/3 in a column, 4/5 offset),
from [schilkp/KiCad_Devices](https://github.com/schilkp/KiCad_Devices) (MIT),
with the two **shield/mounting posts 15 mm apart** plus two shield-ground tabs.
A detailed 3D body (`loopy.pretty/MIDI_DIN5.wrl`, generated from `MIDI_DIN5.scad`
via OpenSCAD — shielded box + square flange + recessed round socket + contact
pins) is attached, oriented so the socket faces out the board edge.

**MIDI IN is opto-isolated per the MIDI spec:** DIN pin 4 → 220 Ω → the **H11L1
optocoupler (U9)**, DIN pin 5 → cathode, a **1N4148 (D2)** across the LED for
reverse protection, output pulled to +5 V and merged to the 328P RX. This is the
mandatory isolation barrier that prevents ground loops between instruments.

**Indicator LEDs** are **not** on the main board — they break out through the
3-pin **J11** header (`+5V_LED` / data / `GND`) to an off-board strip, with only
the 330 Ω series resistor + decoupling staying on the main board.

**3D models:** KiCad 10 ships the `L_12x12mm_H8mm` (L1) and `WS2812B-2020` (ring
LEDs) footprints *without* their `.step` files, so they were invisible in
renders. They're remapped to existing models (`L_Bourns_SRR1260`; `WS2812B-Mini`
scaled to 2.0 mm) — purely cosmetic, no copper/footprint change.

### How the layout was produced (scripted pipeline)

KiCad 10's GUI/standalone `pcbnew` and `kinet2pcb` both crash on netlist→board
auto-place (`assert PgmOrNull()`), but the **`pcbnew` Python module works** for
board manipulation. So the layout is generated by a scripted pipeline (helper
scripts are local-path tooling, gitignored):

1. **Import** netlist → footprints+nets (GUI **File ▸ Import Netlist** once for
   the main board; a small `pcbnew` parser builds the ring board directly).
2. **Place** — courtyard-aware shelf-packing into functional zones, connectors
   pinned to edges, with a self-overlap check.
3. **Route** — export Specctra `.dsn` (`pcbnew.ExportSpecctraDSN`) → **Freerouting
   1.6.5** batch (`-de -do -mp 50`) → import `.ses` (`pcbnew.ImportSpecctraSES`).
   Route at 0.25 mm clearance so the optimizer's nicks stay above the 0.15 DRC limit.
4. **Pour** GND zones both layers + fill → **DRC** (`kicad-cli pcb drc`) → **Gerbers**
   (`kicad-cli pcb export gerbers/drill`).

To regenerate Gerbers from the committed boards:
```sh
kicad-cli pcb export gerbers -o fab/loopy_pedal_main/ kicad/loopy_pedal_main.kicad_pcb
kicad-cli pcb export drill   -o fab/loopy_pedal_main/ kicad/loopy_pedal_main.kicad_pcb
```
