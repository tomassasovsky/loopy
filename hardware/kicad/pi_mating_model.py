"""Attach render-only 3D models of the Raspberry Pi 4 + four standoffs to
loopy_pi_main.kicad_pcb, so the board's OWN 3D viewer (Alt-3) shows the mounted
stack -- no separate file, nothing to download.

The added footprints carry nothing but a 3D model: no pads, no courtyard, no
silk, references hidden, and they are excluded from the BOM and position files.
They are typed THROUGH_HOLE only so KiCad's 3D viewer shows them under its
default filters (a "board only / virtual" footprint can be hidden by the viewer's
visibility toggle).  Gerbers, drill and DRC are byte-for-byte unaffected.

Model paths are portable and shipped in-repo:
  Pi 4    -> ${KIPRJMOD}/3dmodels/RaspberryPi4_ModelB.step  (vendored, ~17 MB)
  standoff-> ${KICAD10_3DMODEL_DIR}/...                     (shipped with KiCad)

Idempotent -- re-run after regenerating the board from the SKiDL pipeline:
    "C:\\Program Files\\KiCad\\10.0\\bin\\python.exe" pi_mating_model.py
"""
import os
import pcbnew

HERE  = os.path.dirname(os.path.abspath(__file__))
BOARD = os.path.join(HERE, "loopy_pi_main.kicad_pcb")
PI = "${KIPRJMOD}/3dmodels/RaspberryPi4_ModelB.step"
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
    # THROUGH_HOLE type (shown by the viewer's default filter) but kept out of the
    # BOM and placement files; it has no pads, so fab output is unchanged.
    fp.SetAttributes(pcbnew.FP_THROUGH_HOLE |
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
