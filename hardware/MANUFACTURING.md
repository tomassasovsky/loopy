# VAMP console — manufacturing package

Everything needed to build one console, grouped by vendor. All enclosure
outputs regenerate from `enclosure/vamp_enclosure.py` (run it before quoting —
it also refreshes the three quote zips below, so they can never go stale).

## 1. Sheet metal (laser cut + bend + powder coat)

Send **`enclosure/out/vamp_sheetmetal.zip`** (DXF flat patterns + PDF drawings
for every part) plus **`enclosure/out/vamp_sheetmetal_step.zip`** (3D reference
STEPs incl. the folded assembly).

| Part | Qty | Notes |
|---|---|---|
| `vamp_base` | 1 | ONE folded blank: floor + 4 walls + rear transition. Weld-free (corner brackets rivet). |
| `vamp_faceplate` | 1 | Sloped lid, full-width blank. Fold conventions in the drawing NOTE (chirality matters). |
| `vamp_corner_bracket_rear` | 2 | Internal L-brackets; ONE part serves both corners (left = flipped). |
| `vamp_rear_panel_pi` | 1 | Rear I/O sub-panel (Pi build). `vamp_rear_panel_nopi` is the alternate build — order one or the other. |
| `vamp_screen_bracket` | 8 | 4 per screen (16" + 7"). |
| `vamp_ring_disc` | 1 | Encoder LED-ring centre disc. |
| `silent_pedal_base` | 10 | Footswitch base tray: 4 walls up 90° (front 18 = taped down-stop, sides 16 = hinge; flats in `silent_pedal/out/`, included in the zip). |
| `silent_pedal_plate` | 10 | Footswitch top: inverted tray, 4 skirts down 90° — clamshell wraps outside the base. |

Material: **2.0 mm 5052-H32 aluminium**, K-factor 0.33, R2 tooling (bend notes
on each drawing). Finish: black powder coat, outside faces. Front-lip M4 holes
are laser-cut then tapped after bending (called out on the drawing).

## 2. 3D printing (FDM)

Send **`enclosure/out/vamp_3dprint.zip`** (STEP + STL for each part).

| Part | Qty | Material | Notes |
|---|---|---|---|
| `vamp_platform_front` | 8 | PETG/ASA, ≥40% infill | Pedal pedestal, 104×79×8.6. Heat-set pilots Ø4.0 both faces — use **short M3×3 inserts** (8 per pedestal). |
| `vamp_platform_mid` | 2 | PETG/ASA, ≥40% infill | Tall (45.9) CLEAR/BANK pedestal, hollow with boss columns — standard **M3×5.7×4.6 inserts** (8 per pedestal). |
| `vamp_led_diffuser` | 6 | **White PLA** | Pill lens, pushes into the faceplate slot from inside. |
| `vamp_ring_diffuser` | 1 | **White PLA** | Annular lens for the encoder LED ring. |
| `rc20_pad/out/asp1_pad` | 1 master | Resin/PLA master | Pedal pad master (96×71 = the silent-pedal treadle, design-controlled) — print once, cast **10× silicone pads** via `asp1_pad_mould`/`asp1_pad_pourbox`. |

Platform top pedal-insert pattern (`ASP1_MOUNT` 55×80) is design-controlled —
it matches the silent-pedal base mount holes by construction.

## 3. PCBs

| Board | Files | Qty | Notes |
|---|---|---|---|
| Main board (`loopy_pedal_main`, THT) | `kicad/fab/loopy_pedal_main_gerbers.zip` + `_bom.csv` + `_cpl.csv` | 1 | The manufactured V1. LCSC part map: `kicad/fab/loopy_combined_bom_lcsc.csv`. |
| Encoder ring PCB | `kicad/fab/loopy_pedal_ring_gerbers.zip` | 1 | |
| LED puck (single WS2812B) | `led_strip/loopy_led_strip_gerbers.zip` | 6 | 16×8 mm, castellated; or buy off-the-shelf WS2812B modules instead (see `led_strip/README.md`). |

(`loopy_pi_main_gerbers.zip` is the **dropped** Pi HAT — do not order.)

## 4. Printed overlay

`enclosure/out/vamp_overlay.dxf` + `.pdf` → die-cut adhesive vinyl/polycarbonate
top overlay (black field, white legends, die-cut apertures). Replaces all
silkscreen on the metal.

## 5. Purchased parts

Full lists with links: **`loopy_console_shopping_list.md`** (console) and
**`loopy_pedal_shopping_list.md`** (board THT parts). Headlines:

- 15.6" 5V USB-C touch panel; APROTII 7" monitor (pedals are sheet metal —
  see `silent_pedal/`: 10× QUIET lever microswitch (Cherry DB3/ZF D4 class),
  10× spring Ø10×25 free ~1.5 N/mm, 20× M4 shoulder screw (Ø5×4 shoulder)
  + Ø5×1 washer + PEM CLS-M4 (hinge pivots), silicone tape (front wall
  tops + a rear strip on each pedestal deck), 10× JST-XH 2-pin pigtail)
- Raspberry Pi 5 + Active Cooler
- 5V buck: **eleUniverse 8–36V→5V 10A IP67** (Amazon B0GGHN97TK) + 9V ≥5A brick
- 1× NeoPixel Ring 16 (authentic Adafruit, 44.5 mm OD — clones are 68 mm and won't fit)
- Heat-set inserts: 64× M3×3 (short) + 16× M3×5.7×4.6, brass
- Fasteners: 40× M3×8 (platform bolts, from below), 40× M3×6 (pedal bases →
  pedestal top inserts — short: the pilots are shallow), 6× M4 (front lip + rear lap),
  10× Ø3.2 pop rivets (corner brackets), 4× M2.5×35.3 Pi risers (stack or turn —
  35.3 mm is derived, see `PI_RISER_H`), 4× M3×12 + standoffs 15 mm (main board),
  2× M4 (buck ears), PEM M4 nuts per drawing
- Cabling per **`loopy_vamp_wiring.md`** (HDMI ×2, USB, 9V Y-harness, JST looms)

## 6. Reference (do not send to vendors)

- `enclosure/out/vamp_assembly.step` — full folded assembly
- `loopy_vamp_enclosure_design.md`, `loopy_vamp_wiring.md` — design + wiring
- Fusion cloud docs: "VAMP sheet metal" (native sheet-metal validation) and
  "VAMP console (populated)" (full visual assembly + exploded storyboard)
