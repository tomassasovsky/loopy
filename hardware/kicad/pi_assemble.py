"""Build a 3D *visualization* assembly: the loopy_pi_main HAT mounted on a
Raspberry Pi 4 with brass standoffs, for rendering only (not a fab artifact).

It writes `_assembly.kicad_pcb` (gitignored) by copying the real board and
attaching render-only 3D models: the Pi 4 below the board and four standoffs in
the gap.  The Pi STEP model is **downloaded on first run** (~17 MB) into
`_models/` (gitignored) rather than committed — same approach as the Freerouting
jar in `_tools/`.

Pi 4 model: Raspberry Pi 4 Model B v4, from the community MGS-CAD-Files repo
(https://github.com/multigamesystem/MGS-CAD-Files) — used here for visualization
only; not redistributed in this repo.
Standoffs: Würth WA-SMSE M3 (shipped with KiCad's 3D model library).

Run with KiCad's bundled python (it has `pcbnew`), then render with kicad-cli:

    "C:\\Program Files\\KiCad\\10.0\\bin\\python.exe" pi_assemble.py
    kicad-cli pcb render --rotate "-72,0,52" --perspective --zoom 0.8 \\
        --quality high --floor -o _asm_hero.png _assembly.kicad_pcb
"""
import os
import shutil
import urllib.request
import pcbnew

HERE   = os.path.dirname(os.path.abspath(__file__))
BOARD  = os.path.join(HERE, "loopy_pi_main.kicad_pcb")
ASM    = os.path.join(HERE, "_assembly.kicad_pcb")
MODELS = os.path.join(HERE, "_models")
PI     = os.path.join(MODELS, "RPi4.step")
PI_URL = ("https://raw.githubusercontent.com/multigamesystem/MGS-CAD-Files/"
          "main/STEP%20files%20with%20images/Raspberry%20Pi%204%20Model%20B%20v4.step")

# Würth M3 standoff from KiCad's bundled 3D library. Adjust the KiCad path if your
# install differs (these scripts target KiCad 10.0, like the rest of the pipeline).
KICAD_3D = r"C:\Program Files\KiCad\10.0\share\kicad\3dmodels"
SO = os.path.join(KICAD_3D, "Mounting_Wuerth.3dshapes",
                  "Mounting_Wuerth_WA-SMSE-ExternalM3_H15mm_9771150360.step")

# ---- fetch the Pi model on first run --------------------------------------
if not os.path.exists(PI):
    os.makedirs(MODELS, exist_ok=True)
    print("downloading Raspberry Pi 4 model (~17 MB) ...")
    urllib.request.urlretrieve(PI_URL, PI)
    print("  saved", PI)

def MM(v):
    return pcbnew.FromMM(v)

# ---- build the assembly from a copy of the real board ----------------------
shutil.copyfile(BOARD, ASM)
b = pcbnew.LoadBoard(ASM)
for fp in list(b.GetFootprints()):
    if fp.GetReference() in ("PI4", "SO1", "SO2", "SO3", "SO4"):
        b.RemoveNative(fp)

def add_model(ref, px, py, fn, off, rot):
    fp = pcbnew.FOOTPRINT(b)
    fp.SetReference(ref)
    fp.Reference().SetVisible(False)
    fp.SetPosition(pcbnew.VECTOR2I(MM(px), MM(py)))
    m = pcbnew.FP_3DMODEL()
    m.m_Filename = fn
    m.m_Offset = pcbnew.VECTOR3D(*off)
    m.m_Rotation = pcbnew.VECTOR3D(*rot)
    m.m_Scale = pcbnew.VECTOR3D(1, 1, 1)
    m.m_Show = True
    fp.Models().push_back(m)
    b.Add(fp)

# Pi 4 below the board (its PCB ~16.5 mm under our board = the standoff gap)
add_model("PI4", 78, 60, PI, (0, 0, -16.5), (0, 0, 0))
# four standoffs at the board's mounting holes (KiCad coords), stud poking up
for ref, (hx, hy) in (("SO1", (49, 37)), ("SO2", (107, 37)),
                      ("SO3", (49, 86)), ("SO4", (107, 86))):
    add_model(ref, hx, hy, SO, (0, 0, -15.0), (0, 0, 0))

pcbnew.SaveBoard(ASM, b)
print("wrote", ASM, "- now render it with kicad-cli pcb render (see this file's docstring)")
