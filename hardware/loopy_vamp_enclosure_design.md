# VAMP — sheet-metal enclosure for the loopy Pi loopstation

A wedge-shaped welded console that houses this repo's standalone build
([`loopy_pi_main`](loopy_pi_main_pcb_design.md)) and **integrates ten foot pedals
into the chassis** the way the real "Chewie II" / Sonnit reference does. Form
(850 × 465 × 100 mm, top sloping toward the player) and layout from the reference;
internals are this project's. Branded **VAMP**.

The deliverable is a **manufacturing package** (STEP + DXF + PDF) produced by the
parametric generator [`enclosure/vamp_enclosure.py`](enclosure/vamp_enclosure.py),
validated by an in-generator **assertion suite** (see §8). Decisions came from
[brainstorm](../docs/brainstorm/2026-06-27-vamp-enclosure-brainstorm-doc.md) →
[research](../docs/research/2026-06-27-vamp-components-research.md) →
[plan](../docs/plan/2026-06-27-feat-vamp-enclosure-rework-plan.md) → technical review.

> **Integrated pedals.** The foot controls are ten **whole Artesia ASP-1 sustain
> pedals** (100 × 75 × 25 mm), modded so their switch leads wire straight to the
> board. Each **stands on a spot-welded inner platform**; its foot-plate protrudes
> through a ~78 × 103 mm slot. **No top-face fasteners; no cables leave the box.**

---

## 1. Overall geometry & construction

| dimension | value | note |
|-----------|-------|------|
| Width `W` | **850 mm** | reference footprint |
| Depth `D` | **412 mm** | sized to a comfortable gap behind the front row (no dead band) |
| Rear height | **100 mm** / front lip **45 mm** | wedge |
| Top slope | **7.6°** | sloped length 416 mm |
| Material | **2.0 mm 5052-H32 aluminium** | bend R 2.0, K 0.33 |

**Construction = welded shell + removable bottom plate.** The faceplate (sloped
top), front wall, rear wall and two side panels are **welded** into one rigid
body; the **bottom plate bolts on** (M4 into PEM nuts in the walls' bottom
return-flanges). Service = flip the unit, unbolt the bottom — the pedals stay on
their fixed platforms and never have to clear the top.

```
  WELDED SHELL (one body)                 REMOVABLE / INSERT PARTS
  ├ faceplate (sloped top, all cutouts)   ├ bottom plate (bolted, vented)
  ├ front wall (45) + bottom flange       ├ 10× inner pedal platform (spot-welded)
  ├ rear wall (100) + I/O + vents + flange├ screen-retention brackets (×4 + ×4)
  └ 2× side panel + bottom flange
```

Weld joints are **callouts** (a `WELD` DXF layer + drawing notes), not modelled
beads. Per-edge intent: the wall **bottom edges fold** (return-flange = PEM-nut
land for the bottom plate); the wall **top edges weld** to the faceplate; the side
**sloped top edges weld** to the faceplate.

---

## 2. Foot pedals on welded inner platforms

Ten whole **Artesia ASP-1** pedals stand inside on spot-welded platforms, the
foot-plates protruding through the top slots — giving the reference's piano-key
look with no visible fasteners and the switch wiring fully internal.

- **Slot:** `FSW_SLOT_W` 78 (u) × `FSW_SLOT_D` 103 (v) mm — the ASP-1 footprint
  (75 × 100) + 3 mm clearance. **No mounting holes** in the faceplate.
- **Platform** (`vamp_platform`, ×10): a folded shelf + two downturned legs with
  weld tabs, **spot-welded** to the front wall + an internal cross-rib. Shelf top
  at **`PLATFORM_H` ≈ 31.5 mm** so the 25 mm pedal body lands the foot-plate flush
  +2 mm proud at the slot. The `PLATFORM_HEADROOM` assertion enforces this against
  the local lid height.
- **Layout (two rows, per the reference):** a front row of **8 evenly-spaced**
  pedals (REC/PLAY · STOP · UNDO · MODE · TRACK 1–4) and an upper pair **CLEAR /
  BANK aligned in `u` over UNDO and MODE**. A **status LED sits aligned above each
  of the four TRACK pedals only** (Ø5.1 THT) — the transport/CLEAR/BANK pedals have
  none. The mid-row platforms are taller (the lid is higher there); the generator
  computes both heights and the depth assertions confirm the 16" screen fits behind.

> **PROVISIONAL.** `FSW_SLOT_*` and `PLATFORM_H` are computed from the ASP-1's
> published 100 × 75 × 25 mm. **Measure a real ASP-1** (foot-plate, body height,
> how proud the plate sits) and set `ASP1_*` before cutting metal; the assertions
> will re-validate the fit.

---

## 3. Top faceplate — control layout (Chewie-II)

`u` = 0…843 L→R (player's left→right), `v` = 0…468 front→rear.

| feature | qty | size (mm) | maps to |
|---------|-----|-----------|---------|
| ASP-1 pedal slot | 10 | 78 × 103 | 8 front (evenly spaced) + CLEAR/BANK over UNDO/MODE, no fasteners |
| track status LED | 4 | Ø5.1 | aligned above TRACK 1–4 only (THT, cabled) |
| 7" touchscreen | 1 | 156 × 88 aperture | waveform / loop view (left), top-aligned |
| 16" touchscreen | 1 | 350 × 199 aperture | main loopy UI (right), top-aligned |
| encoder + diffused ring | 1 | Ø7 + Ø58/40 | centred under the 7" screen, on the CLEAR/BANK height line; EC11 + 12 THT LEDs |
| power / mode LED | 2 | Ø8 | bezel, flanking the encoder |

- **Screens mount from behind**; the aperture is **smaller than the bezel** so the
  monitor clamps against the panel (rear `screen_bracket` parts retain them). The
  16" is a ViewSonic TD1655-class portable touch monitor (355 × 223 × 15 mm).
- **LEDs are 5 mm through-hole, cabled.** The ring is a cut annulus with a diffuser
  + 12 THT LEDs behind.
- **No logo cutout** on the panel (removed). "VAMP" remains the product/drawing name.

---

## 4. Rear I/O & ventilation

Rear wall (`u` = 0…846, `z` = 0…100): **9 V barrel** (Ø12) · **power/shutdown
button** (Ø16) · **fuse** (Ø12) · **USB-A ×2** (the external audio interface +
stick/MIDI) · **M6 earth/bond stud** · a **louvre vent block**. No audio aperture,
no pedal-cable slot — the audio interface is **external**.

**Ventilation** (Pi 5 ≤ 12 W; Active Cooler ramps 60/67.5/75 °C): a rear exhaust
vent block + a bottom-plate intake array give ≈ 17 000 mm² open area (`>` the
4 000 mm² floor the `VENT_FREE_AREA` assertion checks). The Pi mounts on **M3
standoffs ≥ 10 mm** off the bottom plate for under-board airflow and Active-Cooler
intake.

**Grounding:** welded joints are continuous, but powder-coat is an insulator — the
bottom-plate perimeter pads are **masked (un-coated)** for chassis bond, and the
rear earth stud provides the bond point.

---

## 5. Bottom plate (removable, vented)

Flat plate bolting up into the wall flanges' PEM nuts: vent intake array, **Pi/board
M3 standoff pattern** (58 × 49), 4 rubber feet, masked ground pads. Lift it off for
full service access.

---

## 6. Sheet-metal notes

- Folded edges (wall bottom flanges): 90°, inside R = `t` = 2.0, **K 0.33** → bend
  allowance 4.18 mm. Welded edges get a weld gap, no allowance.
- **PEM:** clinch hole Ø6.3 (distinct from M4 Ø4.3 clearance), ≥ 8 mm edge distance
  — the 18 mm flanges host them.
- DXF layers: `CUT` (thru) · `BEND` (score) · `WELD` (callout) · `VENT` ·
  `ENGRAVE` · `NOTE`.
- Finish: deburr → powder coat (mask bond pads).

---

## 7. Material & weight

| material | thickness | mass |
|----------|-----------|------|
| **5052-H32 aluminium** *(default)* | 2.0 mm | **≈ 5.3 kg** |
| Mild steel (CRS) | 2.0 mm | ≈ 15.4 kg |

---

## 8. Generating the package & the assertion gate

```bash
cd hardware/enclosure
python3.12 -m venv .venv && .venv/bin/pip install ezdxf cadquery matplotlib  # one-time
.venv/bin/python vamp_enclosure.py            # check + STEP + DXF + PDF -> out/
.venv/bin/python vamp_enclosure.py --report   # report + assertions only
.venv/bin/python vamp_enclosure.py --no-step   # DXF + PDF only
```

Before any output the generator runs `_check()` — **the real acceptance gate**.
It raises (build fails) unless every geometry rule holds:

| assertion | guards |
|-----------|--------|
| `WIDTH_BUDGET` | the 10-pedal row + gaps fit across the faceplate |
| `NO_OVERLAP` / `BOUNDS` | no two cutouts intersect; all inside the usable area |
| `PLATFORM_HEADROOM` | foot-plate flush+proud, body fits under the sloped lid |
| `SCREEN_DEPTH` | each module + cable clears the interior; pedal row clears the 16" |
| `VENT_FREE_AREA` | open vent area ≥ target; standoff gap adequate |
| `SCREEN_RETENTION` | aperture < bezel (mount from behind) |
| `PEM` | flange wide enough for the clinch nut |

Outputs in `enclosure/out/` (mm): **STEP** (`vamp_assembly` + per-part incl.
`vamp_platform`, `vamp_bottom`), **DXF** flat patterns, **PDF** drawing sheets
(`vamp_platform` is DXF-only). Verification renders
(`out/_hero.png`, `out/_fp_top.png`) confirm 7" left / 16" right.

Everything is parameterised at the top of the script — change a value, re-run, and
the assertions re-validate before re-cutting every panel.

---

## 9. Bill of materials (enclosure only)

| item | qty | note |
|------|-----|------|
| 2.0 mm 5052-H32 sheet | ~1.1 m² | shell + bottom + platforms + brackets |
| PEM M4 clinch nuts | ~16 | bottom-plate fixings |
| M4 screws | ~16 | bottom plate |
| M3 standoffs (≥10 mm) | ~6 | Pi / board, airflow gap |
| M6 earth stud + hardware | 1 | chassis bond |
| Rubber feet | 4 | bottom |
| Screen-retention brackets | 4 + 4 | from `vamp_screen_bracket` |
| Diffuser disc (ring) + 12 THT LEDs | 1 | encoder ring |

Pedals, screens, encoder, LEDs, Pi, board and the (external) audio interface are in
the electronics BOMs / `loopy_pedal_shopping_list.md`.

---

## 10. Confirm before cutting

Two figures must come from the physical parts (both one-line param changes, then
re-run — the assertions re-validate): **`ASP1_*`** (real pedal foot-plate + body,
driving `FSW_SLOT_*` and `PLATFORM_H`) and the exact **`BIG_*`/`SMALL_*`** touch
modules.
