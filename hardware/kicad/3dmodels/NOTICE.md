# Third-party 3D models

## RaspberryPi4_ModelB.step

A 3D STEP model of the Raspberry Pi 4 Model B, used **for visualization only**
(it is attached to `loopy_pi_main.kicad_pcb` as a render-only, board-only model so
the 3D viewer shows the board mounted on a Pi — it is not part of the PCB design,
BOM, or fabrication outputs).

- **Source:** https://github.com/multigamesystem/MGS-CAD-Files
  (file: *STEP files with images/Raspberry Pi 4 Model B v4.step*)
- **License:** the source repository specifies **no license**. It is vendored here
  for convenience at the project owner's request. If you redistribute this repo and
  that matters to you, confirm the model's redistribution terms or swap it for a
  clearly-licensed Pi 4 model (drop a replacement at this path — the board references
  it via `${KIPRJMOD}/3dmodels/RaspberryPi4_ModelB.step`).
- "Raspberry Pi" is a trademark of Raspberry Pi Ltd; this model is not an official
  Raspberry Pi asset.

The standoff models in the assembly come from KiCad's own bundled 3D library
(`${KICAD10_3DMODEL_DIR}/Mounting_Wuerth.3dshapes/...`) and are not vendored here.
