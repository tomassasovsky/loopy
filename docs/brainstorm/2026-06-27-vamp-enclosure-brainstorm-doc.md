---
date: 2026-06-27
topic: vamp-enclosure
---

# VAMP — sheet-metal enclosure for the loopy Pi loopstation

## What We're Building

A wedge-shaped sheet-metal floor console (the **VAMP**) that houses the loopy
standalone build — Raspberry Pi 4/5 + `loopy_pi_main` board + two touchscreens +
encoder + status LEDs — and **integrates ten foot pedals into the chassis** the
way the real "Chewie II" / Sonnit reference does. The form (850 × 465 × 100 mm
wedge, top sloping toward the player) and the control layout are taken from the
reference photos; the internals are this project's.

The deliverable is a **manufacturing package** (3D STEP + flat-pattern DXF + PDF
drawing sheets) produced by a parametric generator, ready to send to a sheet-metal
fabricator. This brainstorm re-grounds the design after an earlier build pass made
wrong assumptions (pedals as external units with cables exiting, an invented audio-
interface aperture, guessed footswitch sizes).

## Why This Approach

The reference is a proven stage looper; replicating its **integrated-pedal wedge**
form (rather than external stomps or a flat desktop box) is what the user wants.
The foot pedals are bought sustain pedals (Artesia ASP-1 / Nektar NP-1 / M-Audio
SP-1) that get **modded**: the foot-plate/switch mechanism is mounted on an
**internal platform** so the plate protrudes through a rectangular top slot —
giving the reference's "piano-key" footswitch look with no visible top fasteners
and no cables leaving the box. A **welded** inner-platform construction was chosen
over tab-and-slot or a sub-chassis for maximum rigidity on a unit that gets
stomped on. **Bottom-plate service access** is the only sane option once pedals
are fixed on inner platforms (they never have to clear the top).

## Key Decisions

- **Integrated pedals on welded inner platforms** — each modded sustain pedal sits
  on a spot-welded internal shelf at a height that puts its foot-plate flush/proud
  through a rectangular top slot. Rationale: reference look, no top-face fasteners,
  rigid, switch wiring stays internal.
- **Cables never exit the box** — all pedal switch leads run internally to the
  loopy board's 2-pin headers. Rationale: user correction; the top slots are for
  the foot-plates, not cable pass-through. (Removes the earlier "rear pedal cable
  slot.")
- **Audio interface is EXTERNAL** — no interface mounted inside, no rear aperture
  for it. The Pi connects to it over USB. Rationale: user decision. Rear panel
  reduces to power + USB + button + fuse.
- **Service via removable bottom plate** — shell (faceplate + front + rear + 2
  sides) is one rigid welded/folded body; the bottom bolts on (PEM nuts). Flip to
  service. Rationale: pedals on fixed platforms can't clear a removable top.
- **Welded construction (option B)** — folded shell + spot-welded inner platforms
  + bolted bottom. Rationale: most rigid; user choice over no-weld tab-and-slot.
- **Layout = Chewie II** — front row of 8 footswitches (REC/PLAY · STOP · UNDO ·
  MODE | TRACK 1–4); CLEAR + BANK as an identical pair top-centre; small **waveform
  screen top-left**; large **main screen top-right**; **encoder low-left** by
  REC/PLAY; **status LEDs above the track switches**; **logo top-left**.
- **Screens: 7" (waveform, left) + 16" (main, right), capacitive touch** — driven
  by the Pi internally (HDMI/DSI + USB touch). Exact glass/bezel/depth confirmed in
  research.
- **LEDs through-hole + cabled** (no SMD); **encoder ring = diffused annulus**;
  7 indicator + per-track status + power/mode.
- **Material: 2.0 mm 5052-H32 aluminium** default (steel optional, heavier).
- **Deliverable: parametric generator** → STEP (assembly + per-part) + DXF flat
  patterns (CUT/BEND/ENGRAVE) + PDF drawing sheets, in `hardware/enclosure/out/`.

## Open Questions

Resolved in the **deep-research** phase (drive exact cutout + platform geometry):

- **Footswitch dimensions** — foot-plate W×D, overall height, switch travel and
  internal mechanism footprint of the chosen sustain pedal (Artesia ASP-1 / Nektar
  NP-1 / M-Audio SP-1). Sets each top slot size + inner-platform height. *Which of
  the three pedals is the build target?*
- **Touchscreen modules** — exact 7" and 16" capacitive-touch module dimensions
  (active area, glass, bezel, board depth, ribbon/connector side, mounting holes).
  Sets the screen cutouts + internal depth/clearance + mounting method.
- **Welded inner-platform geometry** — shelf size, spot-weld pattern, how the pedal
  is retained on the shelf, and the height datum that lands the foot-plate flush in
  the slot.
- **Logo method** — the reference logo is **EL-wire (glowing)**; VAMP could be
  EL-wire, engraved, or backlit. Decide in planning.
- **Internal layout & cooling** — placement of Pi + `loopy_pi_main` board + wiring
  on the bottom plate, ventilation, and routing the 10 pedal leads + 2 screen
  cables.

## Out of Scope / Settled

- No internal audio interface, no audio jacks on the box.
- No external pedal cables / no rear cable slot.
- No removable top faceplate (service is bottom-plate only).
