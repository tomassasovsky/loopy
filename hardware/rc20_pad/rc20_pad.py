#!/usr/bin/env python3
"""
RC-20-style footswitch rubber pad -- 3D-printable MASTER for silicone casting.

Workflow this feeds:  print this master -> make a mould around it -> cast new
silicone pads for your existing footswitches.

Shape basis (traced from the user's reference drawing, ref_clip.png, via pixel
projection):  the pad is
  * an OUTER rounded-rectangle BASE slab (the low level of the rubber), and
  * THREE RAISED rounded-rectangle PLATFORMS stacked along the length --
    a short top strip, a medium middle, and a large bottom press area --
    separated by base-level DIVIDER GROOVES.
Traced proportions (fractions of the outer footprint): side/end border ~1.8 %,
grooves ~5 %, platform lengths ~12 % / 26 % / 48 % of the length. Those RATIOS
are measured; the ABSOLUTE size is anchored to the ~78 mm-per-pad estimate from
the 173 mm unit width, so scale is still yours to confirm.

==> Anything tagged  # MEASURE  must be confirmed with calipers against your
    real pad before you commit a print. The layout is traced; the overall
    footprint/thickness/rise are yours to lock in.

Outputs (./out):  STEP (CAD, editable) + STL (print) + SVG preview views.
Run:  ../enclosure/.venv/bin/python rc20_pad.py      (or this dir's .venv)
"""
from __future__ import annotations
import os
import cadquery as cq

# ----------------------------------------------------------------------------
# PARAMETERS (mm) -- edit these, re-run.
# ----------------------------------------------------------------------------
# -- FIT to the user's foot-pedal top (pedal body 85.9 x 62.8 x 24.6 mm) -----
# The pad glues onto the pedal's TOP face; the 24.6 mm body height is irrelevant.
# The pad is inset FIT_MARGIN per edge so it sits safely WITHIN the pedal top.
PEDAL_L      = 85.9    # pedal top length, front-to-back  # user-measured
PEDAL_W      = 62.8    # pedal top width, across          # user-measured
FIT_MARGIN   = 2.0     # inset per edge (bump up = safer / smaller pad)

# -- outer BASE slab (the whole rubber footprint, low level) ----------------
PAD_L        = PEDAL_L - 2 * FIT_MARGIN   # = 81.9 mm
PAD_W        = PEDAL_W - 2 * FIT_MARGIN   # = 58.8 mm
CORNER_R     = 1.5     # outer plan-view corner radius (ref is near-square)
BASE_H       = 2.0     # base rubber thickness           # MEASURE
EDGE_CHAMFER = 0.6     # bevel on the outer top edge

# -- raised platforms (traced ratios; lengths run top -> bottom along +Y) ---
BORDER         = 1.6   # base border from outer edge to the platforms
GROOVE_W       = 4.5   # base-level groove between platforms
PLATFORM_RISE  = 2.0   # how far the platforms stand proud of the base  # MEASURE
PLATFORM_R     = 1.0   # platform corner radius (ref corners are square)
PLATFORM_BEVEL = 0.5   # chamfer on the platform top edges
# platform lengths as FRACTIONS of the available length (traced from
# ref_clip.png: short strip / middle / large press area). They auto-fill
# whatever PAD_L you set, so the layout survives any resize.
PLATFORM_FRACS = [0.14, 0.30, 0.56]   # short top / middle / large bottom

# -- underside interface (FIT-CRITICAL) -------------------------------------
#   'flat'   : solid pad, flat bottom (glue onto a flat treadle)  <- your choice
#   'recess' : solid pad with a shallow locating pocket (drops over a raised
#              switch top / treadle plate)
#   'cap'    : hollow shell that slips OVER the switch like a cap
UNDERSIDE    = 'flat'
RECESS_L     = 60.0    # locating pocket length          # MEASURE switch top
RECESS_W     = 58.0    # locating pocket width           # MEASURE switch top
RECESS_DEPTH = 4.0     # pocket depth                    # MEASURE
RECESS_R     = 8.0     # pocket corner radius
CAP_WALL     = 3.0     # wall thickness when UNDERSIDE == 'cap'

OUT = os.path.join(os.path.dirname(__file__), "out")


# ----------------------------------------------------------------------------
def _rrect(w: float, l: float, r: float) -> cq.Sketch:
    """Rounded-rectangle sketch, w across X, l across Y."""
    r = max(0.1, min(r, w / 2 - 0.1, l / 2 - 0.1))
    return cq.Sketch().rect(w, l).vertices().fillet(r)


def build():
    # --- outer BASE slab: flat-topped rounded rectangle, bevelled rim -------
    solid = (
        cq.Workplane("XY")
        .placeSketch(_rrect(PAD_W, PAD_L, CORNER_R))
        .extrude(BASE_H)
    )
    if EDGE_CHAMFER > 0:
        try:
            solid = solid.edges(">Z").chamfer(EDGE_CHAMFER)
        except Exception:
            pass

    # --- three raised platforms, stacked from the top (+Y) downwards --------
    plat_w = PAD_W - 2 * BORDER
    ftot = sum(PLATFORM_FRACS)
    avail = PAD_L - 2 * BORDER - (len(PLATFORM_FRACS) - 1) * GROOVE_W
    platforms = [f / ftot * avail for f in PLATFORM_FRACS]   # auto-fill PAD_L
    y_top = PAD_L / 2 - BORDER          # top edge of the first platform
    for h in platforms:
        y_c = y_top - h / 2.0           # platform centre
        plat = (
            cq.Workplane("XY")
            .workplane(offset=BASE_H)
            .placeSketch(_rrect(plat_w, h, PLATFORM_R))
            .extrude(PLATFORM_RISE)
        )
        if PLATFORM_BEVEL > 0:
            try:
                plat = plat.edges(">Z").chamfer(PLATFORM_BEVEL)
            except Exception:
                pass
        solid = solid.union(plat.translate((0, y_c, 0)))
        y_top -= (h + GROOVE_W)         # step down past this platform + groove

    # --- underside interface -------------------------------------------------
    if UNDERSIDE == "recess":
        pocket = (
            cq.Workplane("XY")
            .rect(RECESS_W, RECESS_L)
            .extrude(RECESS_DEPTH)
            .edges("|Z").fillet(RECESS_R)
        )
        solid = solid.cut(pocket)
    elif UNDERSIDE == "cap":
        solid = solid.faces("<Z").shell(-CAP_WALL)
    # 'flat' -> nothing to do

    return solid


# ----------------------------------------------------------------------------
# One-part OPEN mould (Route A: print this, pour rubber in, screed the back).
# The pad has a flat bottom and no undercuts, so it inverts into a simple open
# cavity: platform detail at the bottom, the flat glue-face is the open top.
# The mould's flat top face IS the screed reference -- overfill slightly, then
# scrape flush with a straightedge to get the pad's flat back.
MOLD_WALL  = 8.0   # cavity wall + floor thickness


def build_mould(pad):
    pad_h = BASE_H + PLATFORM_RISE
    # flip the pad so the platforms point DOWN and the flat face is up at z=0
    cav = pad.mirror("XY")                        # z -> -z; flat face now at z=0
    block = (
        cq.Workplane("XY")
        .box(PAD_W + 2 * MOLD_WALL, PAD_L + 2 * MOLD_WALL, pad_h + MOLD_WALL,
             centered=(True, True, False))
        .translate((0, 0, -(pad_h + MOLD_WALL)))  # block top face sits at z=0
    )
    return block.cut(cav)


# ----------------------------------------------------------------------------
# Route B POUR BOX: an open containment you print, seat the finished master in,
# and pour mould silicone into. Box layer lines never touch a pad (they're on
# the OUTSIDE of the silicone), so FDM is fine here. Sized for a durable mould.
BOX_SILWALL = 12.0   # silicone thickness around the pad footprint
BOX_COVER   = 10.0   # silicone over the platform tops
BOX_PLAS    = 3.0    # printed wall + floor thickness
BOX_SEAT    = 0.6    # shallow floor recess that seats/locates the master


def build_pour_box():
    pad_h = BASE_H + PLATFORM_RISE
    inner_w = PAD_W + 2 * BOX_SILWALL
    inner_l = PAD_L + 2 * BOX_SILWALL
    inner_h = pad_h + BOX_COVER
    outer = (
        cq.Workplane("XY")
        .box(inner_w + 2 * BOX_PLAS, inner_l + 2 * BOX_PLAS, inner_h + BOX_PLAS,
             centered=(True, True, False))
        .translate((0, 0, -BOX_PLAS))           # floor from -BOX_PLAS..0
    )
    cavity = (
        cq.Workplane("XY")
        .box(inner_w, inner_l, inner_h + 1.0, centered=(True, True, False))
    )
    seat = (
        cq.Workplane("XY")
        .placeSketch(_rrect(PAD_W, PAD_L, CORNER_R))
        .extrude(-BOX_SEAT)                       # pocket into the floor
    )
    return outer.cut(cavity).cut(seat)


def export(solid):
    os.makedirs(OUT, exist_ok=True)
    base = os.path.join(OUT, "rc20_pad")
    cq.exporters.export(solid, base + ".step")
    cq.exporters.export(solid, base + ".stl")
    for name, d in (("top", (0, 0, 1)), ("front", (0, -1, 0.35)),
                    ("iso", (1, -1, 0.8))):
        cq.exporters.export(
            solid, f"{base}_{name}.svg",
            opt={"projectionDir": d, "showAxes": False,
                 "strokeWidth": 0.4, "width": 640, "height": 480},
        )
    mould = build_mould(solid)
    cq.exporters.export(mould, base + "_mould.step")
    cq.exporters.export(mould, base + "_mould.stl")
    box = build_pour_box()
    cq.exporters.export(box, base + "_pourbox.step")
    cq.exporters.export(box, base + "_pourbox.stl")
    print("wrote master, _mould and _pourbox (.step/.stl) in", OUT)


if __name__ == "__main__":
    export(build())
