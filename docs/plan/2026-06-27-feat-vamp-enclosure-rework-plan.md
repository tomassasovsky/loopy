---
title: "feat: rework VAMP enclosure for integrated pedals, welded platforms & bottom-plate service"
type: feat
date: 2026-06-27
---

## feat: rework VAMP enclosure for integrated pedals, welded platforms & bottom-plate service — Standard

## Overview

Rework the VAMP sheet-metal enclosure generator
([`hardware/enclosure/vamp_enclosure.py`](../../hardware/enclosure/vamp_enclosure.py))
and its manufacturing package to match the decisions from the brainstorm
([`docs/brainstorm/2026-06-27-vamp-enclosure-brainstorm-doc.md`](../brainstorm/2026-06-27-vamp-enclosure-brainstorm-doc.md))
and the dimensioned facts from research
([`docs/research/2026-06-27-vamp-components-research.md`](../research/2026-06-27-vamp-components-research.md)).

The enclosure becomes a **welded wedge shell with a removable bottom plate**,
housing **ten whole Artesia ASP-1 sustain pedals standing on spot-welded inner
platforms** (foot-plates protruding through ~100×75 mm slots, no top-face
fasteners, no cables exiting), a **7" + 16" touchscreen** pair, the encoder +
diffused LED ring, through-hole indicator LEDs, and an **edge-lit engraved PMMA
"VAMP" logo**. The chassis is **vented** for the Pi 5's 12 W. The deliverable stays
a parametric generator emitting **STEP + DXF + PDF**.

## Problem Statement / Motivation

The current generator encodes wrong assumptions surfaced over three rounds of user
feedback: footswitches modelled as flat panel pads with top-face mounting screws;
pedal cables exiting a rear slot; an invented internal audio-interface aperture; a
drop-on top faceplate that can't clear protruding pedals; a plain-engraved logo; no
ventilation; and guessed screen sizes. The brainstorm and research resolved every
one of these into firm decisions. This plan turns those decisions into a concrete,
buildable manufacturing package so the output can actually go to a fabricator.

## Proposed Solution

Restructure the generator around a **welded shell + removable bottom** construction
and an **integrated-pedal** faceplate, regenerating all STEP/DXF/PDF artifacts.

### Construction model (target)

```
  WELDED SHELL (one rigid body)               REMOVABLE / INSERT PARTS
  ├─ faceplate (top, sloped)  ── all cutouts  ├─ bottom plate (bolted, vented)
  ├─ front wall (45)                          ├─ 10× inner pedal platform (spot-welded in)
  ├─ rear wall (100) ── I/O + vents           ├─ PMMA "VAMP" edge-lit insert
  └─ 2× side panels (trapezoid)               └─ (pedals, screens, Pi = bought parts)
```

- **Service:** flip the unit, unbolt the **bottom plate** (M4 into PEM nuts in the
  shell's bottom return-flanges) → full access. Pedals never clear the top.
- **Inner platforms:** small folded brackets, **spot-welded** to the side walls /
  an internal cross-rib, each presenting a flat shelf at a height that lands the
  ASP-1 foot-plate flush/proud in its slot. No fasteners reach the top face.
- **Welds** are represented in the package as **callouts** (a `WELD` DXF layer +
  drawing notes) and as correctly-positioned separate solids in the STEP (no bead
  geometry modelled).

### Faceplate cutout schedule (target)

**Pedal axes (fixes review C1/C2):** the ASP-1 is 100 × 75 × 25 mm = **L × W × H**.
Mounted with the **75 mm width across the panel (`u`)**, the **100 mm length
front-to-back (`v`)**, and the 25 mm body into **−Z** (down into the box). So the
slot is `FSW_SLOT_W=75 (u) × FSW_SLOT_D=100 (v)`, both **provisional**. Width
budget: 8 × 75 = 600 mm across `FP_W` 845 mm → ~245 mm for gaps + the centre
encoder column. A `WIDTH_BUDGET` assertion enforces `n·FSW_SLOT_W + gaps ≤ FP_W`.

| # | feature | qty | size (mm) | notes |
|---|---------|-----|-----------|-------|
| 1 | ASP-1 pedal slot | 10 | ~75 (u) × 100 (v) (**provisional**) | 8 front row (4 transport \| 4 tracks) + CLEAR/BANK pair top-centre; **no mounting holes** |
| 2 | 16" main screen | 1 | ~350 × 199 aperture | mounted from behind; module 355×223×15 |
| 3 | 7" waveform screen | 1 | ~156 × 88 aperture | mounted from behind; module ~165×100 |
| 4 | encoder + diffused ring | 1 | Ø7 + Ø58/40 annulus | 12 THT LEDs behind diffuser |
| 5 | indicator LEDs | 7 | Ø5.1 | THT, cabled |
| 6 | power / mode LED | 2 | Ø8 | bezel |
| 7 | **VAMP edge-lit window** | 1 | ~200 × 60 | backed by engraved PMMA insert + LED edge strip |

### Rear panel (target, simplified)

9 V barrel (Ø12) · power/shutdown button (Ø16) · fuse (Ø12) · USB-A ×2 (14×14) ·
**ventilation slots**. **Removed:** audio aperture, audio sub-panel + its DXF/STEP
part, pedal-cable slot.

### Bottom plate (new, removable + vented)

Flat plate, M4 clearance holes to PEM nuts in the shell flanges; **ventilation
slot array**; **Pi/board standoff pattern** (M3, parametric, with Active-Cooler
intake clearance); 4 rubber feet.

## Technical Considerations

- **Parametric refactor, not rewrite.** Keep the param block + `faceplate_holes()`
  / `rear_holes()` / `_cut_features()` / DXF-emit / STEP / PDF structure; change the
  *content* (schedules, part list, assembly). The boolean-cutter approach for STEP
  holes stays (face-workplane coords proved unreliable earlier).
- **New parts** in the package: `bottom` (vented, removable), `platform` (×10,
  welded), `acrylic_logo` (PMMA insert). **Dropped parts:** `wrap` (replaced by
  separate front/rear/bottom), `rear_subpanel`.
- **Layer additions:** `WELD` (weld callouts), `ACRYLIC` (PMMA insert outline +
  engrave). Existing `CUT`/`BEND`/`ENGRAVE`/`NOTE` keep their meaning.
- **STEP assembly:** welded shell positioned as before but with the faceplate now
  *fixed* (mirror-in-Y fix already correct → 7" left, 16" right from the player);
  add bottom plate, 10 inner platforms under the slots, and ASP-1 stand-in blocks
  (100×75×25) sitting on the platforms to prove foot-plate-flush and clearance.
- **Executable assertions (fixes review R2 — the real acceptance gate).** Every
  fit check is an `assert` in the generator that raises on violation, so "the
  generator runs" *means* the geometry is valid:
  1. `WIDTH_BUDGET`: `8·FSW_SLOT_W + min_gaps + encoder_col ≤ FP_W`.
  2. `NO_OVERLAP`: pairwise bounding-box check across **all** faceplate cutouts
     (slots, 7"/16" apertures, ring, LEDs, logo window) — none may intersect.
  3. `PLATFORM_HEADROOM` (fixes C3): `PLATFORM_H + ASP1_BODY_H + footplate_proud ≤
     local_lid_height(v)` where `local_lid_height(v)=H_FRONT + drop·(v/D) − T`.
     The front row (low `v`) is the binding case.
  4. `SCREEN_DEPTH` (fixes C2): rear-mounted 16" body (15 mm + cable) must clear,
     in `−Z`, both the sloped lid above and, in `v`, the rearmost pedal/platform
     envelope (`v`-interference check).
  5. `VENT_FREE_AREA` (fixes I1): generated bottom+rear slot open area ≥ target
     (param, e.g. ≥ 40 cm² intake + exhaust) and `STANDOFF_H ≥` min under-board gap.
  6. `SCREEN_RETENTION`: bezel overlaps the aperture (aperture < bezel) for both.
- **`FSW_*` provisional.** Slot/platform/pitch driven by `FSW_*` constants; mark
  them PROVISIONAL pending the user measuring a real ASP-1 (foot-plate W×D, body
  height, how proud the plate sits). Platform height modelled as a shim-able datum.
- **Thermal:** vents sized generously; doc notes Active Cooler thresholds
  (60/67.5/75 °C) and Pi-on-standoff airflow per research.
- **No new dependencies.** Runs in the bundled `.venv` (cadquery + ezdxf +
  matplotlib). Artifacts land in `hardware/enclosure/out/`.

## Implementation tasks

### Phase A — Parameters & schedules
- [ ] Param block: add `FSW_SLOT_W=75, FSW_SLOT_D=100` (provisional); **delete**
  `FSW_W/FSW_D/FSW_CUT_W/FSW_CUT_D/FSW_MOUNT`; confirm `BIG=355/199 active`,
  `SMALL=156/88`; add `PLATFORM_W/D/H` (+ `ASP1_BODY_H=25`, `FOOTPLATE_PROUD`) and
  weld-tab geometry, `LOGO_WIN`, `ACRYLIC_*`, `VENT_*` + target free area,
  `STANDOFF_*` (+ `STANDOFF_H` under-board gap), `BOTTOM_*`, and `PEM_*` (clinch
  hole Ø + min edge distance — **distinct from `D_M4` clearance**, fixes I4).
- [ ] **Delete `_add_footswitch()`** (fully dead under the new design); pedal
  features become a plain `_rrect()` slot + `_text()` label (fixes simplicity 2c).
- [ ] `faceplate_holes()`: 10 pedal **slots** (no mounting holes), engraved labels;
  7"/16" apertures (active-area); ring+encoder; 7 indicator + power/mode LEDs;
  **VAMP window** (cut). **Remove the perimeter `FIX` hole loop** — faceplate is
  **welded** to the side walls; add a `NOTE` "WELD to sides, no top fasteners"
  (decides review R3/simplicity 2b).
- [ ] `rear_holes()`: barrel + power + fuse + USB-A ×2 + **vent slots** + an
  **earth/bond stud hole**; remove audio aperture + sub-panel fixings + pedal slot.
- [ ] Add the **assertion suite** (Technical Considerations) as a `_check()` run at
  the top of `main()` so every build validates geometry before emitting.

### Phase B — Part decomposition & flat patterns (ezdxf)
- [ ] Replace `wrap` with separate `front`, `rear`, and add removable `bottom`.
  **Annotate each edge folded-vs-welded** (folded return-flange = bend allowance +
  becomes the PEM-nut land; welded butt edge = weld gap + `WELD` note) — fixes I5.
- [ ] `dxf_bottom()`: outline + vent slot array (≥ free-area target) + Pi/board
  **M3 standoff clearance holes** (holes, not bosses — fixes simplicity 3a) + foot
  holes + perimeter **PEM** fixings + a **masked (un-powder-coated) ground contact
  pad** callout where it bolts to the shell (fixes C4 continuity).
- [ ] `dxf_platform()`: welded inner-platform blank (shelf + weld tabs), `WELD`
  callout; one DXF, qty 10. **No per-part PDF** (simplicity 1c).
- [ ] `dxf_screen_bracket()`: rear clamp/standoff bracket that retains each bezel
  monitor from behind (aperture < bezel); 7" + 16" variants (fixes I2).
- [ ] `dxf_acrylic_logo()`: minimal PMMA insert outline + engrave on `ACRYLIC`
  layer (**DXF only, no titled PDF sheet** — simplicity 1b).
- [ ] Update `dxf_faceplate()` for the new schedule (add a **light-baffle recess**
  note behind `LOGO_WIN` — fixes I3); drop `dxf_rear_subpanel()`.
- [ ] Update `DXF_PARTS` registry (+ `bottom`, `platform`, `screen_bracket`,
  `acrylic`; − `wrap`, `rear_subpanel`).

### Phase C — STEP assembly (cadquery)
- [ ] Rebuild shell from separate welded panels (faceplate fixed) + add `bottom`.
- [ ] Model `platform` solid; place 10 under the slots at the height datum.
- [ ] Add bottom + rear vent slots to the cut solids; Pi standoffs are **holes**,
  not bosses (simplicity 3a). **No ASP-1 stand-in solids** — fit is proven by the
  `PLATFORM_HEADROOM`/`SCREEN_DEPTH` assertions, not mockup geometry (simplicity 1a).
- [ ] Per-part STEP exports incl. `vamp_bottom`, `vamp_platform`,
  `vamp_screen_bracket`, `vamp_acrylic`.

### Phase D — Drawings & PDF
- [ ] Per-part PDF sheets incl. bottom, platform (with weld note), acrylic.
- [ ] Add weld + assembly notes to title blocks; render `WELD`/`ACRYLIC` layers.

### Phase E — Docs & preview
- [ ] Rewrite [`hardware/loopy_vamp_enclosure_design.md`](../../hardware/loopy_vamp_enclosure_design.md):
  welded construction + bottom-plate service, integrated-pedal platforms (+ weld
  spec), simplified rear, ventilation, edge-lit PMMA logo, screen mounting, BOM,
  `FSW_*` PROVISIONAL callout, assembly + service sequences.
- [ ] Update the annotated layout SVG (`vamp_panel_layout.svg`) + legend: pedal
  slots (no holes), 7"/16", logo window, rear simplified, add a **bottom-plate /
  service** view and a **section** showing a pedal on its platform.

### Phase F — Verification
- [ ] **Primary gate:** generator runs with **all assertions passing** (width
  budget, no-overlap, platform headroom, screen depth, vent free-area, retention).
  This is the real acceptance gate, not eyeballing (fixes R2).
- [ ] Confirm cuts via face-count/volume; confirm the artifact list.
- [ ] **Verification renders** (existing cadquery-SVG → cairosvg path, no new dep,
  not generator outputs): assembly (player view, confirm 7" left / 16" right),
  bottom-off service view, and a side section through one pedal/platform — saved as
  `out/_*.png` for review + the design-doc hero only.

## User / fabrication flow analysis

- **Generator-run flow:** `.venv/bin/python vamp_enclosure.py` → report + `out/`
  STEP/DXF/PDF. `--report`, `--no-step`, `--no-pdf` still work. Edge case: missing
  `.venv` → doc gives the one-line recreate command.
- **Fabrication flow:** laser-cut `CUT`, score `BEND`, brake-fold panels, **weld**
  shell + platforms per `WELD` notes, press PEM nuts, powder-coat, laser-cut the
  PMMA insert. Edge case: platform height is the weld-fixture-critical dimension →
  call it out as the gauge to set after measuring the ASP-1.
- **Assembly flow:** mount Pi/board/standoffs + LED looms + screens to the shell;
  drop each ASP-1 onto its platform, wire to the board (internal); fit PMMA insert
  + LED edge strip; bolt on the vented bottom. Edge case: pedal-to-board lead
  length — route inside, no exit.
- **Service flow:** flip, unbolt bottom, access everything; pedals stay put.

## Acceptance Criteria

- [ ] Generator runs clean in `.venv`, writing STEP (assembly + per-part incl.
  `bottom`, `platform`, `acrylic`), DXF (faceplate/front/rear/sideL/R/bottom/
  platform/acrylic with CUT/BEND/ENGRAVE/WELD/ACRYLIC layers), and PDF sheets.
- [ ] Faceplate has **10 pedal slots with no top-face fasteners**, 7"+16"
  apertures (active-area), ring+encoder, 7 indicator + power/mode LEDs, and a
  **VAMP window** (not engraved text).
- [ ] **Removable bottom plate** present: bolted, with vent slots + Pi/board
  standoff pattern + feet.
- [ ] **10 inner platforms** modelled under the slots with **weld callouts**; STEP
  shows ASP-1 stand-ins sitting foot-plate-flush.
- [ ] Rear = barrel + power + fuse + USB-A ×2 + vents **only**; audio aperture,
  sub-panel, and pedal-cable slot are gone.
- [ ] Assembly render (player view) shows **7" left / 16" right**; a **service
  render** (bottom removed) and a **pedal-platform section** are produced.
- [ ] **All geometry assertions pass** (width budget, no-overlap, platform
  headroom, screen depth, vent free-area, screen-bezel overlap) — generator raises
  on any violation.
- [ ] **Screen retention** part present (rear clamp/standoff brackets, aperture <
  bezel); **chassis grounding** present (earth/bond stud + masked contact pad at
  the bottom-plate joint); **PEM** spec distinct from M4 clearance.
- [ ] Per-edge **folded-vs-welded** annotated; PMMA window has a **light-baffle**
  note.
- [ ] `hardware/loopy_vamp_enclosure_design.md` + `vamp_panel_layout.svg` updated;
  `FSW_SLOT_*`/`PLATFORM_*` clearly marked **PROVISIONAL** with the measure-the-
  ASP-1 instruction, and the **pedal axes/orientation** documented.

## Success Metrics

A fabricator can quote and cut from the package without further questions except
the explicitly-flagged ASP-1 measurement; the STEP visibly assembles into a vented
welded wedge with integrated pedals on platforms and a bolt-on bottom.

## Dependencies & Risks

- **FSW_\* provisional (MED, was HIGH).** Real ASP-1 dims unknown; wrong slot =
  re-cut. Mitigation: parameterise + provisional + shim-able platform datum + user
  measures before fab. **Note:** provisional now governs only the *exact value
  within a fitting range* — the `WIDTH_BUDGET`/`PLATFORM_HEADROOM` assertions make
  the generator *refuse* geometrically impossible values (closes review R1).
- **Welded-platform height datum.** Final only after measuring how proud the
  foot-plate sits. Mitigation: model as a parameter; note as the weld-fixture gauge.
- **16" depth vs front wedge height (45 mm).** 15 mm module + cable should fit but
  verify in the fit check; if tight, raise `H_FRONT` or shift the screen rearward.
- **STEP "weld" is callout-only.** Acceptable — beads aren't fab inputs; layer +
  notes carry intent.
- **M-Audio SP-2 not chosen** (ASP-1 selected) → research gap on SP-2 is moot.

## Technical review revisions (2026-06-27)

Incorporated from `/plan-technical-review` (3 parallel agents). **No PR split** —
one coupled file. Critical/important fixes folded in above: pedal **axes defined**
(75 mm across `u`) closing the width-fit blocker (C1/C2); all fit checks promoted to
**executable assertions** as the acceptance gate (R2); **chassis grounding/earth**
added (C4); **screen-retention brackets** added (I2); **quantitative vents +
standoff height** (I1); **PEM clinch spec** distinct from clearance (I4);
**per-edge weld-vs-fold** annotation (I5); **light-baffle** behind the PMMA window
(I3); faceplate is **welded, no `FIX` holes** (R3). Simplifications applied: delete
dead `_add_footswitch()`, **drop ASP-1 stand-in solids** (assertions prove fit),
Pi standoffs as **holes not bosses**, acrylic as a **minimal DXF** (no PDF), no
per-part platform PDF.

## References & Research

- Generator: [`hardware/enclosure/vamp_enclosure.py`](../../hardware/enclosure/vamp_enclosure.py)
- Brainstorm: [`docs/brainstorm/2026-06-27-vamp-enclosure-brainstorm-doc.md`](../brainstorm/2026-06-27-vamp-enclosure-brainstorm-doc.md)
- Research (dims + sources): [`docs/research/2026-06-27-vamp-components-research.md`](../research/2026-06-27-vamp-components-research.md)
- Board context (controls, power, Pi GPIO): [`hardware/loopy_pi_main_pcb_design.md`](../../hardware/loopy_pi_main_pcb_design.md)
- Key dims: Artesia ASP-1 100×75×25 mm; ViewSonic TD1655 355×223×15 mm; Pi 5 ≤12 W, Active Cooler 60/67.5/75 °C.
