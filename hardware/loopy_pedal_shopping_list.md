# Loopy Pedal — Local Shopping List (Argentina)

Quantities are **per pedal**. Building two? Double everything except the modules/PCBs counts noted.
All parts are standard and available at local electronics shops / MercadoLibre.

---

## Semiconductors
- [ ] 74AHCT125N — quad buffer, **DIP-14** ×1
- [ ] H11L1 — optocoupler (MIDI IN), **DIP-6** ×1
- [ ] 1N4148 — signal diode ×1
- [ ] 1N5817 — 1 A Schottky (reverse-protection) ×1
- [ ] P6KE13A — TVS diode ×1

## Resistors (1/4 W, axial)
- [ ] 220 Ω ×3
- [ ] 330 Ω ×2
- [ ] 10 kΩ ×3

## Capacitors
- [ ] 100 nF ceramic, 50 V ("104"), **5 mm lead pitch** ×15
- [ ] 100 µF electrolytic, **25 V** (on the 9 V rail) ×1
- [ ] 470 µF electrolytic, 16 V ×2

## Connectors / Electromechanical
- [ ] MIDI DIN-5 jack — **right-angle, PCB mount** ×2
- [ ] DC barrel jack — 5.5 / 2.1 mm, PCB mount ×1
- [ ] EC11 rotary encoder (with push switch) ×1
- [ ] JST-XH pin header — **2-pin** ×11
- [ ] JST-XH pin header — 3-pin ×1
- [ ] JST-XH pin header — 8-pin ×2  *(board-to-board link)*
- [ ] JST-XH wire housings + crimp pins to match the above *(for the footswitch / cable wiring)*
- [ ] Pin header, 2.54 mm — **1×4** ×1 *(buck module)*
- [ ] Pin header, 2.54 mm — **2×3** ×1 *(ICSP)*

## Modules (off-board)
- [ ] Pro Micro — ATmega32U4, **Vin rated 7–12 V** ×1
- [ ] 5 V buck converter module (e.g. MP1584EN) ×1
- [ ] NeoPixel Ring 16 — WS2812, 16 LEDs ×1
- [ ] Momentary SPST footswitches ×10

## Mechanical
- [ ] M3 screws + standoffs — ~7 mounting holes (4 main + 3 ring) ×1 set
- [ ] Standoffs to mount the NeoPixel ring over the encoder ×1 set

---

## Bare PCBs (2 boards)
No cheap local equivalent in Argentina. The expensive shipping was the **parts** order — two light bare PCBs ship cheaply from **JLCPCB on their own**:
- [ ] `hardware/kicad/fab/loopy_pedal_main_gerbers.zip` → JLCPCB (PCB only, no assembly)
- [ ] `hardware/kicad/fab/loopy_pedal_ring_gerbers.zip` → JLCPCB (PCB only, no assembly)

*(Or use a local Argentine PCB fab to avoid the import entirely.)*

---

### Notes
- Verified caps: **K104K10X7RF5UH5** (Vishay) and **CCT104K85X7RF5FH5A0** (SHM) are both 100 nF / 50 V / X7R / 5 mm-pitch — exact-fit drop-ins. Any equivalent 100 nF 50 V "104" with ~5 mm leads works (bend the leads if pitch differs).
- Pro Micro is powered via **RAW** from the reverse-protected 9 V — the 7–12 V Vin rating is required.
- 9 V barrel jack is wired **centre-negative** (Boss / pedal standard).
- Faceplate **RESET** button (to J20) and an external **ICSP** programmer plug into the headers above for firmware recovery.
