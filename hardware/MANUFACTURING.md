# Segno console — manufacturing package

Everything needed to build one console, grouped by vendor. All enclosure
outputs regenerate from `enclosure/segno_enclosure.py` (run it before quoting —
it also refreshes the three quote zips below, so they can never go stale).

## 1. Sheet metal (laser cut + bend + powder coat)

Send **`enclosure/out/segno_sheetmetal.zip`** (DXF flat patterns + PDF drawings
for every part) plus **`enclosure/out/segno_sheetmetal_step.zip`** (3D reference
STEPs incl. the folded assembly).

| Part | Qty | Notes |
|---|---|---|
| `segno_base` | 1 | ONE folded blank: floor + 4 walls + rear transition. Weld-free (corner brackets rivet). |
| `segno_faceplate` | 1 | Sloped lid, full-width blank. Fold conventions in the drawing NOTE (chirality matters). |
| `segno_corner_bracket_rear` | 2 | Internal L-brackets; ONE part serves both corners (left = flipped). |
| `segno_rear_panel_pi` | 1 | Rear I/O sub-panel (Pi build). `segno_rear_panel_nopi` is the alternate build — order one or the other. |
| `segno_screen_bracket` | 8 | 4 per screen (16" + 7"). |
| `segno_ring_disc` | 1 | Encoder LED-ring centre disc. |

Material: **2.0 mm 5052-H32 aluminium**, K-factor 0.33, R2 tooling (bend notes
on each drawing). Finish: black powder coat, outside faces. Front-lip M4 holes
are laser-cut then tapped after bending (called out on the drawing).

## 2. 3D printing (FDM)

Send **`enclosure/out/segno_3dprint.zip`** (STEP + STL for each part).

| Part | Qty | Material | Notes |
|---|---|---|---|
| `segno_platform_front` | 8 | **BLACK** PETG/ASA, ≥40% infill | Pedal pedestal TUB, 115.4×88.8 (deck 13.2, walls to ~37 with sloped top ~0.3 under the faceplate; deck raised for flush-at-rim seating, issue #373 — pedal case top flush with the slot's upper rim, pad above the metal). Perimeter strips outside the slot opening are relief-shaved to the same under-plate plane. Wall inner faces tucked 0.4 behind the slot cut line, so from above only faceplate shows and the reveal reads as a dark channel. Full-height boss drop-in channels in the side walls; 12-wide rear cable notch. Heat-set pilots Ø4.5 from below — the taller deck now takes the standard **M3 5×5 inserts** (4 per pedestal; short M3×3 no longer needed); 1.2-deep pad pocket in the deck. |
| `segno_platform_mid` | 2 | **BLACK** PETG/ASA, ≥40% infill | Tall CLEAR/BANK tub (deck 57.3, walls to 81.1 — row 2 rearward for label-top alignment #366, deck raised for flush-at-rim seating #373), hollow with boss columns — standard **M3 5×5 inserts** (4 per pedestal) + the same pocket, channels, notch and perimeter relief. |
| `segno_led_diffuser` | 10 | **White PLA** | Pill lens, pushes into the faceplate slot from inside. One per pedal (#366). |
| `segno_ring_diffuser` | 1 | **White PLA** | Annular lens for the encoder LED ring. |

The Cherub WTB-006 has **no base screws** (one horizontal through-screw per
side): retention = the deck pocket + gravity + foot pressure, **PROVISIONAL**.
The old `rc20_pad` `asp1_pad` casting master targeted the retired ASP-1 pedal
and no longer matches any pedal in this design.

## 3. PCBs

| Board | Files | Qty | Notes |
|---|---|---|---|
| Main board (`segno_pedal_main`, THT) | `kicad/fab/segno_pedal_main_gerbers.zip` + `_bom.csv` + `_cpl.csv` | 1 | The manufactured V1. LCSC part map: `kicad/fab/segno_combined_bom_lcsc.csv`. |
| Encoder ring PCB | `kicad/fab/segno_pedal_ring_gerbers.zip` | 1 | |
| LED puck (single WS2812B) | `led_strip/segno_led_strip_gerbers.zip` | 10 | 16×8 mm, castellated; or buy off-the-shelf WS2812B modules instead (see `led_strip/README.md`). One per pedal (#366). |


## 4. Printed overlay

`enclosure/out/segno_overlay.dxf` + `.pdf` → die-cut adhesive vinyl/polycarbonate
top overlay (black field, white legends, die-cut apertures). Replaces all
silkscreen on the metal.

## 5. Purchased parts

Full lists with links: **`segno_console_shopping_list.md`** (console) and
**`segno_pedal_shopping_list.md`** (board THT parts). Headlines:

- 10× Cherub WTB-006 footswitches; 15.6" 5V USB-C touch panel; APROTII 7" monitor
- Raspberry Pi 5 + Active Cooler
- 5V buck: **eleUniverse 8–36V→5V 10A IP67** (Amazon B0GGHN97TK) + 9V ≥5A brick
- 1× NeoPixel Ring 16 (authentic Adafruit, 44.5 mm OD — clones are 68 mm and won't fit)
- Heat-set inserts: **M3 5×5 throughout** (5.0 long × 5.0 OD, pilots Ø4.5), brass —
  40× console pedestals (4 per pedestal) + 8× mini-console pedestals + 3× mini lid.
  (Short M3×3 obsolete since the #373 deck raise gave the front pedestals full pilot depth.)
- Fasteners: 40× M3×8 (platform bolts, from below), 6× M4 (front lip + rear lap),
  10× Ø3.2 pop rivets (corner brackets), 4× M2.5×35.3 Pi risers (stack or turn —
  35.3 mm is derived, see `PI_RISER_H`), 4× M3×12 + standoffs 15 mm (main board),
  2× M4 (buck ears), PEM M4 nuts per drawing
- Cabling per **`segno_wiring.md`** (HDMI ×2, USB, 9V Y-harness, JST looms)

## 6. Reference (do not send to vendors)

- `enclosure/out/segno_assembly.step` — full folded assembly
- `segno_enclosure_design.md`, `segno_wiring.md` — design + wiring
- Fusion cloud docs: "Segno sheet metal" (native sheet-metal validation) and
  "Segno console (populated)" (full visual assembly + exploded storyboard)
