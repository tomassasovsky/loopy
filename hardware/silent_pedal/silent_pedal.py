#!/usr/bin/env python3
"""
VAMP silent footswitch v3 -- SHEET METAL, real pedal architecture.

Two folded 2.0 mm 5052 parts per pedal (x10), same laser+bend process as the
enclosure (flats ride in vamp_sheetmetal.zip). NOTHING folds outward and the
top plate has clear space to travel down:

  BASE  : an open TRAY -- floor + four walls folded UP (enclosure corner
          pattern). Side walls 18 mm tall: they carry the hinge rivet bores
          at the rear AND their silicone-taped tops are the DOWN-STOP the
          treadle lands on (travel = the 4 mm gap above them). Front/rear
          walls stay LOW (8 mm) so the lip and the wire clear them.
  PLATE : flat treadle + short cosmetic front lip (tucks 2 mm inside the
          front wall) + two HINGE TABS folded down from side-edge notches at
          the rear -- their bores line up with the side-wall bores on the
          rivet axis. All folds go DOWN, inside the tray.

Mechanism (commercial sustain-pedal style):
  * hinge: 2x O3.2 rivets through side wall + hinge tab (set loose on a
    washer -> pivots; same rivet tooling as the console corners).
  * return: compression spring O10 on the floor seat, front-centre.
  * UP-stop: M4 retention screw INSIDE the spring -- head recessed into the
    printed pedestal deck below, shaft up through floor + treadle holes,
    nyloc + SILICONE washer on top (hidden under the glued pad). Thread
    depth = rest-height/preload adjustment.
  * DOWN-stop: treadle underside lands on SILICONE TAPE on the side-wall
    tops (~4 mm travel there, ~4.3 mm at the toe).
  * switch: QUIET lever microswitch (Cherry DB3 / ZF D4 class, 2-wire NO)
    on the floor -- plain closure into the board's existing JST inputs.
  * wire: routes over the LOW rear wall through the open gap behind the
    treadle (no hole, no grommet).

SILENCE: contact-quiet microswitch; both stops land on silicone (tape down,
washer up); spring captive on the screw in a greased seat; greased rivets.

ENVELOPE = console ASP1_* placeholder (75 x 100 x 25; plate proud 10 through
the 78 x 103 slot; wall tops pass up through the slot, hidden under the
pad's overhang). Mounts 4x M3 into the pedestal inserts (ASP1_MOUNT).

TUNE: spring spec (feel), retention thread depth (rest height), tape
thickness (down-stop travel), switch lever bend (actuation point).

BOM per pedal (x10): quiet lever microswitch; spring O10 x 20 ~1.5 N/mm;
2x O3.2 rivet + washer (pivots, loose); M4 x 25 + nyloc + silicone washer
(retention); 4x M3 x 12 (pedestal); silicone tape (wall tops); JST-XH pigtail.

NOTE: flat offsets carry EMPIRICAL bend-displacement corrections (a folded
plane's mid-line lands ~RI+T=4 beyond the drawn line; material consumed
fold-to-tip ~7). The formal dev_deduct pass is still owed before fab.

Run:  ../enclosure/.venv/bin/python silent_pedal.py   -> ./out
"""
from __future__ import annotations
import os
import sys
import math
import ezdxf

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")

# ---------------------------------------------------------------- envelope
PED_W, PED_D, PED_H = 75.0, 100.0, 25.0
MOUNT_W, MOUNT_D = 55.0, 80.0             # ASP1_MOUNT pedestal inserts
SLOT_W, SLOT_D = 78.0, 103.0              # faceplate slot

T = 2.0
RI, KF = 2.0, 0.33
BA90 = math.pi / 2.0 * (RI + KF * T)
DED90 = 2.0 * (RI + T) - BA90
# MEASURED fold model (CenterFoldBendLinePosition, verified in Fusion):
# folded extent past the fold line = drawn length + EMP; the folded plane's
# mid-line lands EMP beyond the drawn line.
EMP = DED90 / 2.0                         # ~1.9 mm

# ---------------------------------------------------------------- base (v3)
SIDE_H = 18.0                             # side walls: hinge + down-stop
FR_H = 8.0                                # low front/rear walls
WALL_X = 31.0                             # side wall fold lines (planes ~+-35)
BASE_FOLD_Y = 44.0                        # front/rear fold lines (planes ~+-48)
PIN_Y, PIN_Z = 35.5, 10.0                 # hinge rivet centre
PIN_D = 3.4
SW_HOLES = 22.2                           # microswitch mount pitch (M2.3)
SW_XY = (0.0, -26.0)
SPRING_XY = (0.0, -38.0)                  # spring seat / retention screw axis
TAPE_Y = (-42.0, -10.0)                   # silicone tape zone on wall tops

# ---------------------------------------------------------------- plate (v3)
PLATE_D = 84.0                            # treadle depth (edges at +-42)
LIP_SPAN, LIP_DROP = 31.0, 6.0            # cosmetic front lip (drop below
                                          # the treadle underside)
HTAB_FOLD = 27.5                          # tab fold line (plane ~31.5; 1.5mm
                                          # washer gap to the wall face)
HTAB_Y = (29.0, 42.0)                     # tab span on the side edge (rear)
HTAB_TIP = 4.0                            # tab tip height above the floor

TAPE_T = 1.0                              # silicone tape thickness
PLATE_TOP = PED_H


def _doc():
    d = ezdxf.new()
    d.header['$INSUNITS'] = 4              # millimetres
    for name, color in (("CUT", 7), ("BEND", 4), ("ENGRAVE", 1), ("NOTE", 3)):
        d.layers.add(name, color=color)
    return d


def _poly(msp, pts, layer, closed=True):
    msp.add_lwpolyline(pts, close=closed, dxfattribs={"layer": layer})


def _circle(msp, x, y, dia, layer="CUT"):
    msp.add_circle((x, y), dia / 2.0, dxfattribs={"layer": layer})


def dxf_base(path):
    """Open tray: full-span folds meeting in O6 corner reliefs (the enclosure
    pattern), kerf-trimmed front/rear flaps. Side flaps tall, front/rear low."""
    doc = _doc(); msp = doc.modelspace()
    sw = SIDE_H - EMP
    fw = FR_H - EMP
    L, R = -WALL_X, WALL_X
    y0, y1 = -BASE_FOLD_Y, BASE_FOLD_Y
    K = 0.15
    pts = [(L + K, y0), (L + K, y0 - fw), (R - K, y0 - fw), (R - K, y0),
           (R, y0), (R + sw, y0), (R + sw, y1), (R, y1),
           (R - K, y1), (R - K, y1 + fw), (L + K, y1 + fw), (L + K, y1),
           (L, y1), (L - sw, y1), (L - sw, y0), (L, y0)]
    _poly(msp, pts, "CUT")
    for x in (L, R):
        _poly(msp, [(x, y0), (x, y1)], "BEND", closed=False)
    _poly(msp, [(L + K, y0), (R - K, y0)], "BEND", closed=False)
    _poly(msp, [(L + K, y1), (R - K, y1)], "BEND", closed=False)
    for cx, cy in ((L, y0), (R, y0), (L, y1), (R, y1)):
        _circle(msp, cx, cy, 6.0)
    for x in (R + (PIN_Z - EMP), L - (PIN_Z - EMP)):
        _circle(msp, x, PIN_Y, PIN_D)                     # hinge bores
    for sx in (-1, 1):
        for sy in (-1, 1):
            _circle(msp, sx * MOUNT_W / 2.0, sy * MOUNT_D / 2.0, 3.4)
    for sx in (-1, 1):
        _circle(msp, SW_XY[0] + sx * SW_HOLES / 2.0, SW_XY[1], 2.4)
    _circle(msp, SPRING_XY[0], SPRING_XY[1], 4.5)         # retention screw
    _circle(msp, SPRING_XY[0], SPRING_XY[1], 10.0, "ENGRAVE")   # spring seat
    for sx in (-1, 1):                                    # tape zones
        x = sx * (WALL_X + SIDE_H / 2.0)
        _poly(msp, [(x, TAPE_Y[0]), (x, TAPE_Y[1])], "ENGRAVE", closed=False)
    msp.add_text("VAMP PEDAL BASE v3  2.0mm  x10  open tray: walls UP 90; "
                 "silicone TAPE on the SIDE wall tops at marks (down-stop); "
                 "wire routes OVER the low rear wall",
                 dxfattribs={"layer": "NOTE", "height": 5}).set_placement(
                 (L - sw, y1 + fw + 6))
    doc.saveas(path)


def dxf_plate(path):
    """Treadle + front lip + two hinge tabs folded down from side-edge
    notches at the rear (1 mm relief slit so fold ends land on the outline)."""
    doc = _doc(); msp = doc.modelspace()
    lw = T + LIP_DROP - EMP                             # lip: bottom z 17
    bore_off = PED_H - PIN_Z - EMP                      # tab bore: z = PIN_Z
    W2 = PED_W / 2.0
    y0, y1 = -PLATE_D / 2.0, PLATE_D / 2.0
    hy0, hy1 = HTAB_Y
    hf = HTAB_FOLD
    hd = PED_H - HTAB_TIP - EMP                         # tab: tip z = HTAB_TIP
    pts = [(-LIP_SPAN, y0), (-LIP_SPAN, y0 - lw), (LIP_SPAN, y0 - lw),
           (LIP_SPAN, y0), (W2, y0),
           (W2, hy0 - 1.0), (hf, hy0 - 1.0), (hf, hy0),   # relief slit
           (hf + hd, hy0), (hf + hd, y1), (hf, y1),
           (-hf, y1),
           (-hf - hd, y1), (-hf - hd, hy0), (-hf, hy0),
           (-hf, hy0 - 1.0), (-W2, hy0 - 1.0),
           (-W2, y0)]
    _poly(msp, pts, "CUT")
    _poly(msp, [(-LIP_SPAN, y0), (LIP_SPAN, y0)], "BEND", closed=False)
    for sx in (-1, 1):
        _circle(msp, sx * LIP_SPAN, y0, 6.0)              # fold-end reliefs
        _poly(msp, [(sx * hf, hy0), (sx * hf, hy1)], "BEND", closed=False)
        _circle(msp, sx * hf, hy0, 6.0)
        _circle(msp, sx * hf, hy1, 6.0)
        _circle(msp, sx * (hf + bore_off), PIN_Y, PIN_D)  # hinge bores
    _circle(msp, 0.0, SPRING_XY[1], 4.5)                  # retention screw
    msp.add_text("VAMP PEDAL PLATE v3  2.0mm  x10  lip + hinge tabs DOWN 90 "
                 "(all folds go down, inside the tray); asp1_pad glues on top "
                 "(hides the M4 nyloc + silicone washer)",
                 dxfattribs={"layer": "NOTE", "height": 5}).set_placement(
                 (-W2, y1 + 6))
    doc.saveas(path)


def build_step():
    """Idealized folded assembly STEP (visual reference; the native folds
    live in the Fusion doc)."""
    import cadquery as cq
    base = cq.Workplane("XY").box(2 * WALL_X + 2 * T, 2 * BASE_FOLD_Y + 2 * T,
                                  T, centered=(True, True, False))
    for sx in (-1, 1):
        base = base.union(
            cq.Workplane("XY").box(T, 2 * BASE_FOLD_Y, SIDE_H,
                                   centered=(True, True, False))
            .translate((sx * (WALL_X + EMP), 0, 0)))
    for sy in (-1, 1):
        base = base.union(
            cq.Workplane("XY").box(2 * WALL_X - 0.3, T, FR_H,
                                   centered=(True, True, False))
            .translate((0, sy * (BASE_FOLD_Y + EMP), 0)))
    base = base.cut(cq.Workplane("YZ").cylinder(90, PIN_D / 2, centered=True)
                    .translate((0, PIN_Y, PIN_Z)))
    plate = (cq.Workplane("XY").box(PED_W, PLATE_D, T,
                                    centered=(True, True, False))
             .translate((0, 0, PED_H - T)))
    plate = plate.union(
        cq.Workplane("XY").box(2 * LIP_SPAN, T, LIP_DROP + T,
                               centered=(True, True, False))
        .translate((0, -PLATE_D / 2 - EMP, PED_H - T - LIP_DROP - T)))
    for sx in (-1, 1):
        plate = plate.union(
            cq.Workplane("XY").box(T, HTAB_Y[1] - HTAB_Y[0],
                                   PED_H - HTAB_TIP,
                                   centered=(True, True, False))
            .translate((sx * (HTAB_FOLD + EMP),
                        (HTAB_Y[0] + HTAB_Y[1]) / 2, HTAB_TIP)))
    plate = plate.cut(cq.Workplane("YZ").cylinder(90, PIN_D / 2, centered=True)
                      .translate((0, PIN_Y, PIN_Z)))
    assy = cq.Assembly()
    assy.add(base.val(), name="base", color=cq.Color(0.12, 0.12, 0.12))
    assy.add(plate.val(), name="plate", color=cq.Color(0.15, 0.15, 0.15))
    assy.save(os.path.join(OUT, "silent_pedal_assy.step"))


def checks():
    under = PED_H - T                                # treadle underside
    stop = SIDE_H + TAPE_T                           # tape top
    travel = under - stop                            # at the wall contact
    assert 3.0 <= travel <= 5.0, "down-stop travel out of range"
    toe = travel * (PIN_Y + 48.0) / (PIN_Y + PLATE_D / 2.0)
    # walls + tab planes stay inside the faceplate slot; washer gap between
    wall_mid, tab_mid = WALL_X + EMP, HTAB_FOLD + EMP
    assert 2 * (wall_mid + T / 2) <= SLOT_W - 2.0, "walls foul slot"
    gap = (wall_mid - T / 2) - (tab_mid + T / 2)
    assert 1.0 <= gap <= 2.5, "hinge tab / wall washer gap off"
    # lip clears the low front wall through the whole travel
    lip_bot = under - LIP_DROP
    lip_pressed = lip_bot - travel * (PIN_Y + 46.0) / (PIN_Y + PLATE_D / 2.0)
    assert lip_pressed > FR_H + 1.0, "lip hits the front wall"
    assert HTAB_TIP > T + 0.5, "hinge tab hits the floor"
    # bore edge margins in the flats
    tab_dev = PED_H - HTAB_TIP - EMP
    bore_off = PED_H - PIN_Z - EMP
    assert tab_dev - bore_off - PIN_D / 2 >= 1.5, "tab bore too near tip"
    assert min(PIN_Y - HTAB_Y[0], HTAB_Y[1] - PIN_Y) - PIN_D / 2 - 3.0 \
        >= 1.0, "tab bore too near the fold-end reliefs"
    assert SIDE_H - EMP - (PIN_Z - EMP) - PIN_D / 2 >= 1.5, \
        "wall bore too near wall top"
    print("travel %.1f mm at the walls / %.1f at the toe | walls %.0f+tape | "
          "pin (y%.1f z%.1f) | lip bottom %.1f pressed %.1f"
          % (travel, toe, SIDE_H, PIN_Y, PIN_Z, lip_bot, lip_pressed))


def main():
    os.makedirs(OUT, exist_ok=True)
    checks()
    dxf_base(os.path.join(OUT, "silent_pedal_base.dxf"))
    dxf_plate(os.path.join(OUT, "silent_pedal_plate.dxf"))
    print("DXF flats: out/silent_pedal_base.dxf, out/silent_pedal_plate.dxf")
    sys.path.insert(0, os.path.join(HERE, "..", "enclosure"))
    try:
        from vamp_enclosure import dxf_to_pdf
        for n in ("silent_pedal_base", "silent_pedal_plate"):
            dxf_to_pdf(os.path.join(OUT, n + ".dxf"),
                       os.path.join(OUT, n + ".pdf"),
                       title=n.replace("_", " ").upper())
            print("PDF: out/%s.pdf" % n)
    except Exception as e:
        print("(pdf skipped: %s)" % e)
    try:
        build_step()
        print("Folded STEP: out/silent_pedal_assy.step")
    except Exception as e:
        print("(step skipped: %s)" % e)


if __name__ == "__main__":
    main()
