"""Build a standalone 3D *visualization* assembly: the loopy_pi_main HAT mounted
on a Raspberry Pi 4 with brass standoffs, written to `_assembly.kicad_pcb`
(gitignored) for isolated renders.

You normally don't need this -- the Pi + standoffs are already attached to
`loopy_pi_main.kicad_pcb` itself (see pi_mating_model.py), so opening that board
and pressing Alt-3 shows the stack.  This script just produces a separate file.

Models are shipped in-repo (nothing is downloaded):
  Pi 4    -> 3dmodels/RaspberryPi4_ModelB.step  (see 3dmodels/NOTICE.md)
  standoff-> KiCad's bundled Würth 3D library

Run with KiCad's bundled python, then render with kicad-cli:
    "C:\\Program Files\\KiCad\\10.0\\bin\\python.exe" pi_assemble.py
    kicad-cli pcb render --rotate "-72,0,52" --perspective --zoom 0.8 \\
        --quality high --floor -o _asm_hero.png _assembly.kicad_pcb
"""
import os
import shutil
import pcbnew

HERE  = os.path.dirname(os.path.abspath(__file__))
BOARD = os.path.join(HERE, "loopy_pi_main.kicad_pcb")
ASM   = os.path.join(HERE, "_assembly.kicad_pcb")
PI    = os.path.join(HERE, "3dmodels", "RaspberryPi4_ModelB.step")
KICAD_3D = r"C:\Program Files\KiCad\10.0\share\kicad\3dmodels"
SO = os.path.join(KICAD_3D, "Mounting_Wuerth.3dshapes",
                  "Mounting_Wuerth_WA-SMSE-ExternalM3_H15mm_9771150360.step")

def MM(v):
    return pcbnew.FromMM(v)

shutil.copyfile(BOARD, ASM)
b = pcbnew.LoadBoard(ASM)
for fp in list(b.GetFootprints()):
    if fp.GetReference() in ("PI4", "SO1", "SO2", "SO3", "SO4"):
        b.RemoveNative(fp)

def add_model(ref, px, py, fn, off):
    fp = pcbnew.FOOTPRINT(b)
    fp.SetReference(ref)
    fp.Reference().SetVisible(False)
    fp.SetPosition(pcbnew.VECTOR2I(MM(px), MM(py)))
    m = pcbnew.FP_3DMODEL()
    m.m_Filename = fn
    m.m_Offset = pcbnew.VECTOR3D(*off)
    m.m_Rotation = pcbnew.VECTOR3D(0, 0, 0)
    m.m_Scale = pcbnew.VECTOR3D(1, 1, 1)
    m.m_Show = True
    fp.Models().push_back(m)
    b.Add(fp)

add_model("PI4", 78, 60, PI, (0, 0, -16.5))
for ref, (hx, hy) in (("SO1", (49, 37)), ("SO2", (107, 37)),
                      ("SO3", (49, 86)), ("SO4", (107, 86))):
    add_model(ref, hx, hy, SO, (0, 0, -15.0))

pcbnew.SaveBoard(ASM, b)
print("wrote", ASM, "- render it with kicad-cli pcb render (see this file's docstring)")
