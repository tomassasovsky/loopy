"""Attach render-only 3D models of the Raspberry Pi 4 + four standoffs to
loopy_pi_main.kicad_pcb, so the board's OWN 3D viewer (Alt-3) shows the mounted
stack -- without a separate assembly file.

The added footprints are BOARD-ONLY: no pads, no courtyard, no silk, references
hidden -> they are excluded from the BOM, position files and netlist, and are
invisible on every 2D / fab layer, so Gerbers and DRC are unaffected.  They carry
nothing but a 3D model.

Model paths are portable:
  Pi 4    -> ${KIPRJMOD}/_models/RPi4.step   (download it once with pi_assemble.py;
             gitignored, so other clones show a missing-model placeholder until then)
  standoff-> ${KICAD10_3DMODEL_DIR}/...      (shipped with KiCad)

Idempotent -- re-run it after regenerating the board from the SKiDL pipeline.

Run with KiCad's bundled python:
    "C:\\Program Files\\KiCad\\10.0\\bin\\python.exe" pi_mating_model.py
"""
import os
import pcbnew

HERE  = os.path.dirname(os.path.abspath(__file__))
BOARD = os.path.join(HERE, "loopy_pi_main.kicad_pcb")
PI = "${KIPRJMOD}/_models/RPi4.step"
SO = ("${KICAD10_3DMODEL_DIR}/Mounting_Wuerth.3dshapes/"
      "Mounting_Wuerth_WA-SMSE-ExternalM3_H15mm_9771150360.step")

def MM(v):
    return pcbnew.FromMM(v)

b = pcbnew.LoadBoard(BOARD)
for fp in list(b.GetFootprints()):
    if fp.GetReference() in ("PI4", "SO1", "SO2", "SO3", "SO4"):
        b.RemoveNative(fp)

def add(ref, px, py, fn, off):
    fp = pcbnew.FOOTPRINT(b)
    fp.SetReference(ref)
    fp.SetAttributes(pcbnew.FP_BOARD_ONLY |
                     pcbnew.FP_EXCLUDE_FROM_POS_FILES |
                     pcbnew.FP_EXCLUDE_FROM_BOM)
    fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)
    fp.SetPosition(pcbnew.VECTOR2I(MM(px), MM(py)))
    m = pcbnew.FP_3DMODEL()
    m.m_Filename = fn
    m.m_Offset = pcbnew.VECTOR3D(*off)
    m.m_Rotation = pcbnew.VECTOR3D(0, 0, 0)
    m.m_Scale = pcbnew.VECTOR3D(1, 1, 1)
    m.m_Show = True
    fp.Models().push_back(m)
    b.Add(fp)

# Pi 4 below the board (PCB ~16.5 mm down = the standoff gap)
add("PI4", 78, 60, PI, (0, 0, -16.5))
# four standoffs at the mounting holes
for ref, (hx, hy) in (("SO1", (49, 37)), ("SO2", (107, 37)),
                      ("SO3", (49, 86)), ("SO4", (107, 86))):
    add(ref, hx, hy, SO, (0, 0, -15.0))

pcbnew.SaveBoard(BOARD, b)
print("added render-only Pi + standoff models to", BOARD)
