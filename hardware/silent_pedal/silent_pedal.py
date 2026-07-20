#!/usr/bin/env python3
"""
VAMP silent footswitch -- SHEET METAL, conventional pedal construction.

Two folded 2.0 mm 5052 parts, same process/material as the enclosure (rides
in the same laser+bend quote package):

  BASE  : floor + two upturned side walls (hinge pin holes) + an upturned
          FRONT FLANGE with a vertical slot (the travel limiter).
  PLATE : treadle + two down-turned side skirts (pin holes) + a front lip.

Construction = what's inside a commercial sustain/footswitch pedal:
  * rear HINGE: M3 x 45 screw + nyloc through base walls + plate skirts.
  * compression SPRING at the front returns the plate UP.
  * an M4 limiter screw through the plate's front lip rides in the flange
    slot; a rubber grommet on its shank meets the slot's top edge at rest
    (silent up-stop) -- the standard slotted-bracket pedal construction.
  * a QUIET MICROSWITCH (Cherry DB3 / ZF D4 class "silent" lever micro,
    2-wire NO) on the floor, pressed near the end of travel -> reads as a
    plain closure on the main board's existing 2-pin JST inputs.

SILENCE (the requirement that started this):
  * quiet-series microswitch instead of a clacking stomp switch.
  * DOWN-stop: the plate's front lip lands on Ø8 silicone bumpons stuck on
    the floor (positions on the ENGRAVE layer) -- plate meets the base's
    borders on rubber, never metal-on-metal.
  * UP-stop: the limiter grommet (rubber) against the slot top -- the
    spring return lands on rubber too.
  * spring seats on adhesive silicone dots (marked), greased hinge screw.

ENVELOPE = the console's ASP1_* placeholder (75 x 100 x 25, plate proud
10 mm through the 78 x 103 faceplate slot); mounts with 4x M3 into the
printed pedestal's inserts (ASP1_MOUNT 55 x 80). The asp1_pad silicone pad
glues on the treadle.

TUNE (hardware is never the paper ideal):
  * feel     = spring spec (Ø10 x 20 free, ~1.5 N/mm).        # TUNE
  * actuation= microswitch lever bend / shim under the switch. # TUNE
  * travel   = LIP height vs bumpon stack (add a second bumpon to shorten).

BOM per pedal (x10): quiet lever microswitch, spring, M3x45+nyloc (hinge),
M4x16+nyloc+Ø6 silicone sleeve (limiter), 4x M3 x 12 (to pedestal),
4x Ø8 x 2.2 bumpons, JST-XH 2-pin pigtail.

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
MOUNT_W, MOUNT_D = 55.0, 80.0            # ASP1_MOUNT pedestal inserts
SLOT_W, SLOT_D = 78.0, 103.0             # faceplate slot

T = 2.0                                   # 5052-H32, same as the enclosure
RI, KF = 2.0, 0.33
BA90 = math.pi / 2.0 * (RI + KF * T)      # 90-deg bend allowance
DED90 = 2.0 * (RI + T) - BA90             # 90-deg bend deduction

# ---------------------------------------------------------------- base
WALL_H = 16.0                             # side wall height (pin at 12)
WALL_X = 31.0                             # wall fold lines at +-31
PIN_Y, PIN_Z = 40.0, 12.0                 # hinge pin centre (rear, depth +40)
PIN_D = 3.4                               # M3 screw hinge
FLANGE_Y = -44.0                          # front limiter flange fold line
FLANGE_H, FLANGE_W = 13.5, 40.0           # flange height / width (centred)
LIM_SLOT = (6.5, 10.0)                    # limiter slot w x h (z 2.5..12.5);
                                          # M4 wears a Ø6 silicone sleeve
LIM_Z_REST = 9.5                          # limiter screw axis at rest
LIM_SLOT_Z0 = 2.5                         # slot bottom above the floor
SW_HOLES = 22.2                           # microswitch mount pitch (M2.3)
SW_XY = (0.0, -26.0)
SPRING_XY = (0.0, -38.0)                  # engrave mark, adhesive spring seat
BUMP_FLOOR = [(-26.0, -42.0), (26.0, -42.0)]   # under the front lip
# ---------------------------------------------------------------- plate
SKIRT_X = 35.5                            # skirt fold lines at +-35.5
SKIRT_H = 13.0                            # skirt drop; pin hole lands at z=12
LIP_H = 15.1                              # front lip drop -> ~4 mm toe travel
BUMP_H = 2.2


def _doc():
    d = ezdxf.new()
    for name, color in (("CUT", 7), ("BEND", 4), ("ENGRAVE", 1), ("NOTE", 3)):
        d.layers.add(name, color=color)
    return d


def _poly(msp, pts, layer, closed=True):
    msp.add_lwpolyline(pts, close=closed, dxfattribs={"layer": layer})


def _circle(msp, x, y, dia, layer="CUT"):
    msp.add_circle((x, y), dia / 2.0, dxfattribs={"layer": layer})


def dxf_base(path):
    """Flat: floor 75 x 100 with two side-wall wings (+ their rear tabs).
    Wing root = fold line at x=+-31; developed wing width = WALL_H - DED90.
    The rear TAB folds inward from the wall TOP edge (second 90-deg fold)."""
    doc = _doc(); msp = doc.modelspace()
    ww = WALL_H - DED90                    # developed wall width
    fw = FLANGE_H - DED90                  # developed flange width
    L, R = -WALL_X, WALL_X                 # wall fold lines
    y0, y1 = -PED_D / 2.0, PED_D / 2.0
    fx = FLANGE_W / 2.0
    pts = [(L, y0), (-fx, y0), (-fx, FLANGE_Y),          # front edge, flange
           (-fx, FLANGE_Y - fw + (FLANGE_Y - y0)) if False else (-fx, y0 - 0),
           ]
    # floor outline with a front flange wing between x=+-fx (fold at FLANGE_Y
    # is INSIDE the floor; the wing hangs off the front edge y0)
    pts = [(L, y0), (-fx, y0), (-fx, y0 - fw), (fx, y0 - fw), (fx, y0),
           (R, y0), (R + ww, y0), (R + ww, y1), (L - ww, y1), (L - ww, y0)]
    _poly(msp, pts, "CUT")
    for x in (L, R):
        _poly(msp, [(x, y0), (x, y1)], "BEND", closed=False)      # wall folds
    _poly(msp, [(-fx, y0), (fx, y0)], "BEND", closed=False)       # flange fold
    # limiter slot in the flange (z 3..13 -> flat offsets from the fold)
    sw2, sh = LIM_SLOT[0] / 2.0, LIM_SLOT[1]
    z0f = LIM_SLOT_Z0 - T
    _poly(msp, [(-sw2, y0 - z0f), (sw2, y0 - z0f),
                (sw2, y0 - z0f - sh), (-sw2, y0 - z0f - sh)], "CUT")
    # hinge pin holes in the walls: distance from fold = PIN_Z - T (outside flat)
    for x in (R + (PIN_Z - T), L - (PIN_Z - T)):
        _circle(msp, x, PIN_Y, PIN_D)
    # floor: pedestal M3s, microswitch M2.3s, spring + bumpon marks
    for sx in (-1, 1):
        for sy in (-1, 1):
            _circle(msp, sx * MOUNT_W / 2.0, sy * MOUNT_D / 2.0, 3.4)
    for sx in (-1, 1):
        _circle(msp, SW_XY[0] + sx * SW_HOLES / 2.0, SW_XY[1], 2.4)
    _circle(msp, SPRING_XY[0], SPRING_XY[1], 10.0, "ENGRAVE")   # spring seat
    for x, y in BUMP_FLOOR:
        _circle(msp, x, y, 8.0, "ENGRAVE")                      # bumpon marks
    msp.add_text("VAMP PEDAL BASE  2.0mm  x10  walls UP 90, front flange UP 90"
                 " (limiter slot); stick Ø8 bumpons on floor marks; hinge M3x45"
                 "; M4 limiter + grommet in slot",
                 dxfattribs={"layer": "NOTE", "height": 5}).set_placement(
                 (L - ww, y1 + 6))
    doc.saveas(path)


def dxf_plate(path):
    """Flat: treadle 75 x 100 with two skirts (pin holes) + front lip."""
    doc = _doc(); msp = doc.modelspace()
    sw = SKIRT_H - DED90
    lw = LIP_H - DED90
    L, R = -SKIRT_X, SKIRT_X
    y0, y1 = -PED_D / 2.0, PED_D / 2.0
    pts = [(L, y0 - lw), (R, y0 - lw), (R, y0),          # front lip
           (R + sw, y0), (R + sw, y1),                   # right skirt
           (R, y1), (L, y1),
           (L - sw, y1), (L - sw, y0), (L, y0)]
    _poly(msp, pts, "CUT")
    _poly(msp, [(L, y0), (R, y0)], "BEND", closed=False)          # lip fold
    for x in (L, R):
        _poly(msp, [(x, y0), (x, y1)], "BEND", closed=False)      # skirt folds
    # skirt pin holes: plate underside is at 23; pin at z=12 -> 11 below,
    # hole distance from fold in the flat = 23 - PIN_Z - T
    for x in (R + (23.0 - PIN_Z - T), L - (23.0 - PIN_Z - T)):
        _circle(msp, x, PIN_Y, PIN_D)
    # limiter screw hole in the front lip (axis at LIM_Z_REST at rest)
    _circle(msp, 0.0, y0 - (23.0 - LIM_Z_REST - T), 4.5)
    msp.add_text("VAMP PEDAL PLATE  2.0mm  x10  skirts+lip DOWN 90; "
                 "asp1_pad glues on top; slides under the base rear tabs",
                 dxfattribs={"layer": "NOTE", "height": 5}).set_placement(
                 (L - sw, y1 + 6))
    doc.saveas(path)


def build_step():
    """Idealized folded STEP (assembly for the Fusion doc + console)."""
    import cadquery as cq
    base = (cq.Workplane("XY").box(2*WALL_X + 2*T, PED_D, T,
                                   centered=(True, True, False)))
    for sx in (-1, 1):
        wall = (cq.Workplane("XY").box(T, PED_D, WALL_H,
                                       centered=(True, True, False))
                .translate((sx * (WALL_X + T/2) - T/2 * 0, 0, 0)))
        wall = wall.translate((sx * WALL_X + sx * T / 2 - sx * T / 2, 0, 0))
        base = base.union(
            cq.Workplane("XY").box(T, PED_D, WALL_H,
                                   centered=(True, True, False))
            .translate((sx * (WALL_X + T / 2), 0, 0)))

    flange = (cq.Workplane("XY").box(FLANGE_W, T, FLANGE_H,
                                     centered=(True, True, False))
              .translate((0, FLANGE_Y - T / 2, 0)))
    flange = flange.cut(cq.Workplane("XZ").box(LIM_SLOT[0], LIM_SLOT[1], 10)
                        .translate((0, FLANGE_Y, LIM_SLOT_Z0 + LIM_SLOT[1] / 2)))
    base = base.union(flange)
    base = base.cut(cq.Workplane("YZ").cylinder(90, PIN_D / 2, centered=True)
                    .translate((0, PIN_Y, PIN_Z)))
    for sx in (-1, 1):
        for sy in (-1, 1):
            base = base.cut(cq.Workplane("XY").cylinder(T, 1.7,
                            centered=(True, True, False))
                            .translate((sx * MOUNT_W / 2, sy * MOUNT_D / 2, 0)))
    plate = (cq.Workplane("XY").box(PED_W, PED_D, T,
                                    centered=(True, True, False))
             .translate((0, 0, PED_H - T)))
    for sx in (-1, 1):
        plate = plate.union(
            cq.Workplane("XY").box(T, PED_D, SKIRT_H,
                                   centered=(True, True, False))
            .translate((sx * SKIRT_X, 0, PED_H - T - SKIRT_H)))
    plate = plate.union(
        cq.Workplane("XY").box(PED_W, T, LIP_H, centered=(True, True, False))
        .translate((0, -PED_D / 2 + T / 2, PED_H - T - LIP_H)))
    plate = plate.cut(cq.Workplane("YZ").cylinder(90, PIN_D / 2, centered=True)
                      .translate((0, PIN_Y, PIN_Z)))
    pin = (cq.Workplane("YZ").cylinder(80, 1.5, centered=True)
           .translate((0, PIN_Y, PIN_Z)))
    assy = cq.Assembly()
    assy.add(base.val(), name="base", color=cq.Color(0.12, 0.12, 0.12))
    assy.add(plate.val(), name="plate", color=cq.Color(0.15, 0.15, 0.15))
    assy.add(pin.val(), name="pin", color=cq.Color(0.6, 0.6, 0.65))
    assy.save(os.path.join(OUT, "silent_pedal_assy.step"))
    return base, plate


def checks():
    # plate + skirts must clear the faceplate slot
    plate_w = 2 * SKIRT_X + 2 * T
    assert plate_w <= SLOT_W - 2.0, "skirts foul the faceplate slot"
    # toe travel: lip bottom at rest vs bumpon stack on the floor
    lip_bot = PED_H - T - LIP_H
    travel_lip = lip_bot - (T + BUMP_H)
    toe = travel_lip * (PIN_Y + PED_D / 2) / (PIN_Y + PED_D / 2 - 8.0)
    print("plate width %.1f (slot %.1f) | lip travel %.1f -> toe ~%.1f mm"
          % (plate_w, SLOT_W, travel_lip, toe))
    assert 3.5 <= travel_lip <= 7.0, "travel outside the quiet/positive range"
    # limiter: Ø6 sleeve on the M4 rides the slot; rest = sleeve at slot top;
    # the bumpons (down-stop) must engage BEFORE the sleeve hits slot bottom
    slot_top = LIM_SLOT_Z0 + LIM_SLOT[1]
    slot_travel = LIM_Z_REST - (LIM_SLOT_Z0 + 3.0)
    assert abs((slot_top - 3.0) - LIM_Z_REST) < 0.6, "rest axis vs slot top"
    assert travel_lip <= slot_travel - 0.2, \
        "bumpons must stop the plate before the slot bottom does"
    # flange must stay under the faceplate (lid line ~15 above the base floor)
    assert FLANGE_H <= 13.5, "flange pokes through the faceplate slot"


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
