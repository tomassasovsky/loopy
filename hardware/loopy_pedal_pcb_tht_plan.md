# Loopy foot-pedal — THT redesign plan (mostly through-hole)

Plan to re-spin the **main board** ([main_board.py](kicad/main_board.py)) around
**hand-solderable, mostly-THT** parts for DIY / pedal-builder assembly. **The ring
board ([ring_board.py](kicad/ring_board.py)) is out of scope and stays unchanged
(SMD).** Supersedes the main-board half of the SMD design in
[loopy_pedal_pcb_design.md](loopy_pedal_pcb_design.md).
**Status: BUILT — routed + DRC-clean (see §7).**

## 0. The decision that drives everything

The ATmega16U2 (USB-MIDI bridge) has **no through-hole package**. Resolution:
**replace the 328P + 16U2 with an Arduino Pro Micro (ATmega32U4, USB-C,
5 V/16 MHz) module** that does **class-compliant USB-MIDI in firmware** (native
USB, `MIDIUSB`) instead of the MocoLUFA serial-bridge trick. The module mounts on
two 1×12 female header rows in the board interior; **its USB-C is cable-extended
to the enclosure faceplate**, so there is no board USB receptacle to solder.

This **deletes whole subsystems** vs. the SMD design:

| Deleted vs. the SMD design | Why it's gone |
|---|---|
| ATmega16U2 + crystal, caps, reset, ICSP-16U2, DFU jumper | the module *is* the USB device |
| MocoLUFA / dualMoco mode-select jumper | native USB-MIDI, no firmware-on-bridge |
| **MIDI-IN AND-merge** gate (74HCT08) | USB-in and DIN-in are now **separate transports** (USB stack vs. `Serial1`), no merge |
| onboard USB-C receptacle, USBLC6 ESD, CC/22 Ω, both crystals, ideal-diode ORing, DTR cap | all on the Pro Micro module |

What's left on the board is small and THT: the **module sockets**, **LED buck**,
**DIN MIDI in/out**, **footswitch/ring/indicator connectors**, the **DIP buffer +
opto**, and **reverse-polarity protection**. The module is the only non-THT part
on the main board (its WS2812-driving SMD bits live on the module/ring board).

> **Firmware:** `firmware/loopy_pedal_328p` + MocoLUFA are replaced by the
> **32U4 sketch** in `firmware/loopy_pedal_32u4`: `MIDIUSB` for USB-MIDI, `Serial1`
> (D0/D1) for DIN-MIDI, `FastLED` for both strips. The Pro Micro's Arduino pin
> numbers map straight to the firmware (footswitches D2–D10/D14, ring D15,
> indicator D16, encoder A0–A2, DIN D0/D1).

## 1. Pin budget

The 32U4 has ample GPIO; the 17 signals used:

| count | use | pins |
|---|---|---|
| 10 | footswitches (active-low, internal pull-ups) | D2–D10, D14 |
| 1 | indicator-strip data (off-board via header) | D16 |
| 1 | ring-strip data (→ buffer → cable) | D15 |
| 3 | encoder A / B / SW | A0 / A1 / A2 |
| 2 | DIN MIDI **out / in** on `Serial1` | **D1 (TX) / D0 (RX)** |

= 17 signals. USB-MIDI rides the module's native USB — no UART contention with the
DIN port on `Serial1`. The two 1×12 sockets follow the SparkFun pinout, so the
Arduino pin numbers above map straight to the module pins.

## 2. Component conversion — main board

| SMD part (SMD design) | THT replacement | notes |
|---|---|---|
| ATmega328P-AU **+** 16U2-AU (2× TQFP-32) | **Pro Micro (32U4, USB-C) module** on 2× 1×12 sockets | native USB-MIDI; USB cabled to faceplate |
| USB-C receptacle + USBLC6 ESD + CC/22 Ω + crystals | **on the module** | nothing to solder on the board |
| 2× `74AHCT1G125` (SOT-23-5) | **1× 74AHCT125N DIP-14** | 4 buffers: ring-data + MIDI-out, 2 spare |
| `74AHCT1G08` merge gate | **deleted** | USB-in / DIN-in are separate transports |
| `AP63203WU` buck (SOT-23-6) + L + caps | **buck module (§3)** | LED 5 V rail only (~1.2 A) |
| 2× `LM66100` ideal-diode ORing | **deleted** | module's onboard reg/USB handle power switching |
| `H11L1` opto | **H11L1 DIP-6** | MIDI-IN isolation |
| `AO3401A` reverse-prot P-FET (SOT-23) | **1N5817 series Schottky** (THT) | ~0.3 V drop, fine on 9 V |
| `SMAJ12A` TVS (SMA) | **P6KE13A** axial TVS | across 9 V in |
| barrel jack, 2× DIN-5 RA, JST/pin headers | unchanged | already THT |
| all 0603 R/C | **¼ W axial R, disc/radial C** | |

## 3. LED buck — pick one (both fully THT-friendly)

The **WS2812 strips need ~1.2 A at 5 V**, so a dedicated buck makes the 5 V rail
(`+5V_LED`).

**Powering via `RAW` (the module's onboard regulator).** The 9 V (reverse-protected
`+9V`) feeds the Pro Micro `RAW` pin; the module's onboard regulator makes `VCC`
(5.0 V) for the MCU + 5 V logic (U1/U2). The chosen module is rated **Vin 7–12 V**
(a real regulator with headroom, not a 6 V-class clone LDO), so 9 V is in-spec —
after D1's ~0.35 V Schottky drop `RAW` sees ~8.65 V (>7 V). The buck powers **only**
the `+5V_LED` ring rail (~1 A), which the small onboard reg could never source.
There is **no buck→logic OR-diode** (D4 removed). Modes:

| Connected | MCU + logic 5 V | LED ring |
|---|---|---|
| USB only | USB (VBUS→VCC); buck off | dark (gated — see below) |
| 9 V only (standalone) | RAW → onboard reg → VCC (5.0 V) | lit (buck) |
| USB + 9 V | module arbitrates USB vs RAW-reg | lit (buck) |

> **Phantom-power gate (learned on the first build).** "USB-only = dark" is NOT
> automatic: with the buck off, the MCU/buffer still drive the WS2812 data lines
> at 5 V while `+5V_LED` floats, so current leaks through each first LED's DIN
> protection diode and **phantom-powers the strips** (measured ~4.4 V idle on
> `+5V_LED`, sagging under load — out of spec, stresses that diode). Fix: a
> **100k/47k divider from `+9V` to A3** (`LED_PWR_SENSE`) lets the firmware sense
> the 9 V supply and hold the data lines LOW when it is absent (32U4 sketch
> `LED_POWER_SENSE`). NOTE: the Pro Micro back-feeds `RAW`/`+9V` from USB VBUS
> (RAW ≈ VBUS on USB — per the SparkFun schematic, a family trait, not clone-
> specific), so A3 reads ~1.6 V on USB-only vs ~2.8 V with 9 V — the firmware threshold
> sits between them, not at 0. The first fabricated boards lack this divider (add
> it as a 2-resistor hand-mod, or set `LED_POWER_SENSE 0` to accept the phantom).

This gives a solid 5.0 V on `VCC` (no diode-drop margin worry) and isolates the MCU
supply from the ~1 A of LED switching noise. Trade-off: it ties you to ≥7 V-rated
modules — a 6 V-class clone would be damaged by 9 V on `RAW`. The input TVS guards
the `+9V` rail feeding both the buck and `RAW`.

- **Option A — drop-in buck module** (MP1584EN / LM2596 mini-board on 0.1″ header
  pins): cheapest, smallest, no inductor math.
- **Option B — LM2576-5.0 (TO-220)**: fixed 5 V, 100 µH THT inductor + 1N5822
  Schottky + electrolytics — fully discrete.

**Built with Option A.** `9 V → buck → +5V_LED` (LED ring only); `9 V → RAW →
onboard reg → VCC` (MCU + logic). On USB-only the module runs from USB and the
LEDs stay dark **only because the firmware gates them** off the A3 9 V-sense (see
the phantom-power note above); without that gate they glow of their own accord.
The buck is required for the LED ring in standalone.

## 4. Ring / encoder board — module-hosting, all-THT respin

The original 32× WS2812-2020 SMD ring was dropped (miserable to hand-solder; the
2020 LED + EC11 also lack 3D models in KiCad 10). Replaced with a board that
**hosts an off-the-shelf 16-LED WS2812-5050 NeoPixel ring module** and is
otherwise fully through-hole:

- **60 mm round disc**, 2-layer, GND pours both faces. Built/routed with the
  **KiCad 10** toolchain (`_build_ring.py` + `_route_ring.sh` + `_import_ring.py`).
  The 3× M3 holes sit on the **outer rim (radius 26 mm)**, outside the module's
  44.5 mm OD, so the screws clear the ring module's PCB.
- **EC11 encoder front-centre** (shaft through the module's centre hole). The
  8-pin main-board link (J1, JST-XH), bulk cap and encoder pull-ups/filter mount
  on the **back**. **TWO connection options to the NeoPixel ring, same nets:**
  - `J2` (`loopy:WirePads_1x04`) — 4 flat front pads in the module's centre hole
    for **flying wires** (5V/GND/DIN/DOUT-spare).
  - `J3` (`loopy:ModuleMountPads_4`) — **4 THT pads placed exactly under the
    Adafruit Ring 16's JP1/JP3/JP4/JP2 pads** (DIN @124°, +5V @214°, GND @304°,
    DOUT @79°, r≈21 mm, from the Adafruit EAGLE board file) so the ring can be
    **pin-mounted** straight down onto the disc. The DOUT pin carries the spare
    DOUT net but is mainly there to solder a 4th post for mechanical rigidity.
  3× M3 mounting holes on the outer rim.
- The NeoPixel ring mounts on standoffs over the disc, LEDs up — either wired to
  J2 or pinned into J3. 16 LEDs ≈ **0.96 A peak**, so the main board's original
  ~1.2 A buck is fine (no ≥3 A unit needed).
- Interface to the main board unchanged: 8-pin `+5V_LED ×2 / GND ×2 / RING_DATA /
  ENC_A/B/SW` — drop-in with the main board J6 header.
- **DRC 0/0** (errors); 2 cosmetic silk nits on the dense centre. Gerbers:
  `fab/loopy_pedal_ring_gerbers.zip`.
- **3D models all present.** The EC11's KiCad model isn't installed, so the
  encoder footprint+model are vendored from the real part (**LCSC C202365**,
  `loopy:RotaryEncoder_EC11` + `loopy.pretty/RotaryEncoder_EC11.step`). The
  NeoPixel ring is shown via a visual-only `loopy:NeoPixel_Ring16` footprint
  built to the **real Adafruit geometry** (annular PCB 44.5/31.75 mm,
  `NeoPixel_PCB.wrl`; 16× the stock WS2812-5050 model; the 4 real JP through-hole
  pads; and 4 solid mount posts dropping onto J3) — so the 3D viewer shows the true
  assembly. Mesh-only (VRML `IndexedFaceSet`; KiCad ignores Box/Cylinder
  primitives), Y authored to match the board. It's the *virtual* 3D-model
  category, so it hides/shows independently in the viewer.

## 5. Net effect (main board)

| | SMD design | THT redesign |
|---|---|---|
| main-board ICs | 6 (2× TQFP, 4× SOT) | **Pro Micro module + 1 DIP buffer + 1 DIP opto** |
| crystals | 2 | 0 (on the module) |
| hand-solder difficulty | TQFP-32 ×2 + SOT-23 + 0603 | sockets + axial/disc + DIP |
| USB | onboard 16U2 + USB-C + MocoLUFA flash | module USB-C, cabled to faceplate, native USB-MIDI |
| firmware | 328P thin-client **+** MocoLUFA | one 32U4 sketch (`MIDIUSB`+`FastLED`) |
| SMD holdouts on the board | (all SMD) | none (the Pro Micro module is the only pre-assembled part) |

## 6. Decisions (locked)

1. **MCU/USB:** Arduino Pro Micro (32U4, **USB-C**) module, native USB-MIDI; its
   USB-C is cable-extended to the enclosure faceplate (no board USB receptacle).
2. **Buck:** Option A drop-in module.
3. **Reverse protection:** 1N5817 series Schottky.
4. **Layout:** all connectors flush on the board edges; module + logic interior.

## 7. Execution status — board BUILT (routed, DRC-clean)

1. ✅ **`main_board.py` (Pro Micro module) regenerated** — single **Biacco42
   ProMicro footprint** (`loopy:ProMicro`, 24-pad, wired to its pad numbering;
   pad 1=TX next to USB-C … 24=RAW) with a real 3D model from g200kg
   (`sparkfun_pro_micro.x3d`, offset-calibrated). DIP buffer + opto, Schottky
   reverse-prot, buck-module header, THT discretes; 16U2/MocoLUFA/merge-gate/
   ORing/USB-section deleted. Netlist ERC **0 errors**. `main_board.py` is
   cross-platform (Win/macOS/Linux symbol paths). (`ring_board.py` untouched.)
   Power: **`RAW` = reverse-protected `+9V`** → the module's onboard reg makes
   `VCC`; the buck feeds **only** `+5V_LED` (no D4 OR-diode). A **100k/47k divider
   from `+9V` to A3** (`LED_PWR_SENSE`) drives the firmware's phantom-power gate
   (§3). *(The first fabricated boards, rev Y4, predate this divider — it is a
   2-resistor hand-mod there; the source now has it for the next spin.)*
2. ✅ **Placed (functional zones), routed, poured, verified** via a scripted
   pipeline (gitignored `_*.py`/`_*.sh`). **Only the external connectors are
   edge-mounted and overhang the bottom edge** — barrel (rot 90) + 2× DIN-5 MIDI
   (rot 90, socket facing off-edge). The DIN footprint is the **official LCSC/
   EasyEDA footprint for the actual part — HAOYU DIN-504, LCSC C23689428** (pulled
   via `easyeda2kicad`): pads 1/2/3 ⌀1.3 + 4/5/6/7 ⌀1.6, with the real 3D model
   (`loopy:MIDI_DIN5_RA`, model offset calibrated to align). MIDI signal pins
   4/5; the mounting posts (pads 6/7) are GND. Per the MIDI 1.0 spec, OUT (J4)
   pin 2 = shield→GND, but **IN (J5) pin 2 floats** (preserves opto isolation).
   **Pro Micro placed horizontal at the left edge so its USB-C overhangs
   the board edge** — the faceplate extension cable plugs straight in, no run
   across the board. Everything else is interior, **grouped by function**:
   footswitch JSTs each paired with their debounce cap (5×2), power group
   (reverse-prot + bulk caps + buck) below the module, MIDI group (opto +
   resistors) by the DIN jacks, ring + indicator on the right. **4× M3 mounting
   holes** (`MountingHole_3.2mm_M3_Pad`, GND/chassis-bonded) on a clean rectangle
   at the four corners (9.5/94.5 × 9.5/96.5 mm). Board **94 × 96 mm** (≤100×100).
   **Fully silkscreen-labelled** (built in `_build_board.py`, survives routing):
   every footswitch by function (REC/STOP/UNDO/MODE/TRK1–4/CLR/BANK), connectors
   (9V CTR-, MIDI IN, MIDI OUT, RING, LEDS, 5V BUCK, PRO MICRO, RESET, ICSP) +
   board title, **plus component values** (R/C/D/U) at 0.8 mm — 23/27 placed; the
   4 in the densest spots (C1/C2/C15 = 100nF, D1 = 1N5817) keep their ref-des and
   BOM row and duplicate an identical labelled part alongside. Ref-des + values
   collision-placed against bodies, pads and footprint silk (cathode `K` / `+`
   marks); mounting-hole refs hidden (tight corners); overhanging connector silk
   clipped — **0 silk DRC warnings, 0 overlaps**. Built on the **KiCad 10**
   toolchain (file format v10, matching the ring board).
   **Power:** 9 V barrel jack is wired **centre-negative** (Boss / guitar-pedal
   standard; D1 still blocks a wrong centre-positive supply, it just won't power)
   and silk-marked `9V CTR-`.
   **Firmware serviceability:** normal reflash is USB-C only (1200 bps touch →
   Caterina bootloader, no teardown). For the failure modes: **J20** is a 2-pin
   header to a faceplate momentary **RESET** button (RST→GND, double-tap forces
   the bootloader when a hung sketch blocks USB), and **J21** is a standard 6-pin
   **ICSP** header to un-brick the bootloader with a USBasp (shares the SPI pins;
   MISO/D14 carries the BANK debounce cap, so reflash at a slow ISP clock).
   GND stitching-via grid, **Freerouting 1.9.0** autoroute (GND as copper), SES
   import, GND pours both layers at priority 1 (above the mounting-hole footprint
   zones; solid connection + island removal). Routed at 0.25 mm; DRC clearance
   0.14 mm, copper-to-edge 0.3 mm (both > JLC floors). Result: **DRC 0 violations
   / 0 unconnected**, board **94 × 96 mm, 2-layer**. Gerbers+drill
   (`fab/loopy_pedal_main_gerbers.zip`) + BOM/CPL exported (50 parts).
3. ✅ **32U4 firmware skeleton** —
   [`firmware/loopy_pedal_32u4/`](firmware/loopy_pedal_32u4/): native USB-MIDI
   (`MIDIUSB`) + `Serial1` DIN out + both MIDI-in transports read, footswitch
   debounce. Looper state machine, `FastLED` output, encoder→action stubbed.

> **Before fabricating:** electrically complete + DRC-clean, but confirm against
> your enclosure — exact edge offsets and the DIN/barrel cutout positions, the
> Pro Micro socket-row pitch vs. your actual module (modelled at 0.6″), and the
> panel cutouts for the faceplate RESET button (wired to J20). Route a short
> internal USB-C extension from the module to a panel USB-C jack.
