#!/usr/bin/env python3
"""
VAMP silent footswitch -- SHEET METAL, conventional pedal construction.

Two folded 2.0 mm 5052 parts, same process/material as the enclosure (rides
in the same laser+bend quote package):

  BASE  : floor + two side walls + a REAR wall + a full-width FRONT FLANGE
          with a vertical slot (the travel limiter). Closed on all sides.
  PLATE : treadle + two side skirts (hinge holes) + front lip + REAR skirt --
          at rest the pedal reads as a solid closed body, like a commercial
          unit. Wire exits through a notch at the rear wall's floor line.

Construction = what's inside a commercial sustain/footswitch pedal:
  * rear HINGE: 2x Ø3.2 semi-tubular/pop RIVETS (one per side, set LOOSE
    against a washer so the joint pivots) -- same rivet tooling as the
    console's corner brackets.
  * compression SPRING at the front returns the plate UP.
  * up-stop = the FACEPLATE itself: two ears bent out from the skirts ride
    under the lid on silicone tape -- rest height self-references the lid,
    so the foot-plate always sits exactly flush+proud as designed.
  * a QUIET MICROSWITCH (Cherry DB3 / ZF D4 class "silent" lever micro,
    2-wire NO) on the floor, pressed near the end of travel -> reads as a
    plain closure on the main board's existing 2-pin JST inputs.

SILENCE (the requirement that started this):
  * quiet-series microswitch instead of a clacking stomp switch.
  * DOWN-stop: the plate's front lip lands on Ø8 silicone bumpons stuck on
    the floor (positions on the ENGRAVE layer) -- plate meets the base's
    borders on rubber, never metal-on-metal.
  * UP-stop: skirt ears + silicone tape against the faceplate underside --
    the spring return lands on rubber too.
  * spring seats on adhesive silicone dots (marked), greased hinge screw.

ENVELOPE = the console's ASP1_* placeholder (75 x 100 x 25, plate proud
10 mm through the 78 x 103 faceplate slot); mounts with 4x M3 into the
printed pedestal's inserts (ASP1_MOUNT 55 x 80). The asp1_pad silicone pad
glues on the treadle.

TUNE (hardware is never the paper ideal):
  * feel     = spring spec (Ø10 x 20 free, ~1.5 N/mm).        # TUNE
  * actuation= microswitch lever bend / shim under the switch. # TUNE
  * travel   = LIP height vs bumpon stack (add a second bumpon to shorten).

BOM per pedal (x10): quiet lever microswitch, spring, 2x Ø3.2 rivet +
washer (pivot, set loose), silicone tape pads on the ears,
4x M3 x 12 (to pedestal), 4x Ø8 x 2.2 bumpons, JST-XH 2-pin pigtail
(exits the Ø6 rear-wall hole, runs under the lid to the board).

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
BASE_FOLD_Y = 44.0                        # base front/rear fold lines: folded
                                          # wall planes land at ~+-48
PIN_D = 3.4                               # Ø3.2 pivot rivets, loose-set
REAR_WALL_H = 16.0                        # base rear wall (also 56 wide)

WIRE_HOLE_Z = 9.0                         # Ø6 wire hole; edge stays 4mm clear
                                          # of the rear fold band
FLANGE_Y = -49.0                          # flange plane centre (folds at the
                                          # floor front edge; outermost face)
FLANGE_H = 13.5                           # front wall height (full-width
                                          # wing, enclosure-style corners)
EAR_Y = (-26.0, -14.0)                    # up-stop ear span along the skirt
EAR_Z = 12.5                              # ear top face; +0.5 silicone tape
                                          # = lid underside (13.0): the LID
                                          # is the silent up-stop
EAR_W = 6.0                               # ear reach beyond the skirt
SW_HOLES = 22.2                           # microswitch mount pitch (M2.3)
SW_XY = (0.0, -26.0)
SPRING_XY = (0.0, -38.0)                  # engrave mark, adhesive spring seat
BUMP_FLOOR = [(-26.0, -42.0), (26.0, -42.0)]   # under the front lip
# ---------------------------------------------------------------- plate
SKIRT_X = 33.9                            # skirt folds; folded planes land
                                          # ~4mm outboard (bend arc), so the
                                          # skirts end at ~+-38 in the slot
PLATE_D = 88.0                            # treadle depth: folded lip/rear
                                          # planes land at ~+-48
                                          # planes stay inside the 103 slot
SKIRT_H = 17.0                            # skirt drop (dev 15.1: hosts the pin
                                          # bore 13.5 from the fold, z=12 folded)
LIP_H = 15.1                              # front lip drop -> ~4 mm toe travel
BUMP_H = 2.2


def _doc():
    d = ezdxf.new()
    d.header['$INSUNITS'] = 4          # millimetres (Fusion imports at scale)
    for name, color in (("CUT", 7), ("BEND", 4), ("ENGRAVE", 1), ("NOTE", 3)):
        d.layers.add(name, color=color)
    return d


def _poly(msp, pts, layer, closed=True):
    msp.add_lwpolyline(pts, close=closed, dxfattribs={"layer": layer})


def _circle(msp, x, y, dia, layer="CUT"):
    msp.add_circle((x, y), dia / 2.0, dxfattribs={"layer": layer})


def dxf_base(path):
    """Flat: floor + side-wall wings + full-width front flange (limiter slot)
    + rear-wall wing with a wire notch at the fold line."""
    doc = _doc(); msp = doc.modelspace()
    ww = WALL_H - DED90                    # developed wall width
    fw = FLANGE_H - DED90                  # developed flange width
    rw = REAR_WALL_H - DED90               # developed rear wall
    L, R = -WALL_X, WALL_X                 # side wall fold lines
    y0, y1 = -BASE_FOLD_Y, BASE_FOLD_Y     # front/rear fold lines
    K = 0.15                               # butt-edge kerf (enclosure pattern)
    pts = [(L + K, y0), (L + K, y0 - fw), (R - K, y0 - fw), (R - K, y0),
           (R, y0), (R + ww, y0), (R + ww, y1), (R, y1),
           (R - K, y1), (R - K, y1 + rw), (L + K, y1 + rw), (L + K, y1),
           (L, y1), (L - ww, y1), (L - ww, y0), (L, y0)]
    _poly(msp, pts, "CUT")
    for x in (L, R):
        _poly(msp, [(x, y0), (x, y1)], "BEND", closed=False)      # side walls
    _poly(msp, [(L + K, y0), (R - K, y0)], "BEND", closed=False)  # front wall
    _poly(msp, [(L + K, y1), (R - K, y1)], "BEND", closed=False)  # rear wall
    for cx, cy in ((L, y0), (R, y0), (L, y1), (R, y1)):
        _circle(msp, cx, cy, 6.0)          # corner bend relief (enclosure Ø6)
    _circle(msp, 0.0, y1 + (WIRE_HOLE_Z - T), 6.0)   # Ø6 wire exit, rear wall
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
    """Flat: treadle 75 x 98 with skirts, front lip and rear skirt."""
    doc = _doc(); msp = doc.modelspace()
    sw = SKIRT_H - DED90
    lw = LIP_H - DED90
    rsw = 12.0 - DED90                     # rear skirt drop 12
    L, R = -SKIRT_X, SKIRT_X
    y0, y1 = -PLATE_D / 2.0, PLATE_D / 2.0
    lx = 31.0                              # lip span (3mm off the skirt bands)
    rx = 31.0                              # rear skirt span
    ey0, ey1 = EAR_Y
    sk_ear = (23.0 - EAR_Z) - DED90        # shorter skirt at the ear segment
    ear_out = sk_ear + (EAR_W - DED90)     # ear outer edge in the flat
    pts = [(L, y0), (-lx, y0), (-lx, y0 - lw), (lx, y0 - lw), (lx, y0),
           (R, y0),
           (R + sw, y0), (R + sw, ey0),                   # right skirt (front)
           (R + sk_ear, ey0), (R + ear_out, ey0),         # ear step out
           (R + ear_out, ey1), (R + sk_ear, ey1),
           (R + sw, ey1), (R + sw, y1),                   # right skirt (rear)
           (R, y1), (rx, y1),
           (rx, y1 + rsw), (-rx, y1 + rsw),               # rear skirt
           (-rx, y1), (L, y1),
           (L - sw, y1), (L - sw, ey1),                   # left skirt (rear)
           (L - sk_ear, ey1), (L - ear_out, ey1),         # ear step out
           (L - ear_out, ey0), (L - sk_ear, ey0),
           (L - sw, ey0), (L - sw, y0)]
    _poly(msp, pts, "CUT")
    _poly(msp, [(-lx, y0), (lx, y0)], "BEND", closed=False)       # lip fold
    _poly(msp, [(-rx, y1), (rx, y1)], "BEND", closed=False)       # rear
    for x in (L, R):
        _poly(msp, [(x, y0), (x, y1)], "BEND", closed=False)      # skirt folds
    _poly(msp, [(R + sk_ear, ey0), (R + sk_ear, ey1)], "BEND", closed=False)
    _poly(msp, [(L - sk_ear, ey0), (L - sk_ear, ey1)], "BEND", closed=False)
    # skirt pin holes: plate underside is at 23; pin at z=12 -> 11 below,
    # hole distance from fold in the flat = 23 - PIN_Z - T
    ph = 13.5      # empirical: bore lands at z=12 folded (arc-after-line)
    for x in (R + ph, L - ph):
        _circle(msp, x, PIN_Y, PIN_D)

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

    flange = (cq.Workplane("XY").box(2 * WALL_X - 0.3, T, FLANGE_H,
                                     centered=(True, True, False))
              .translate((0, FLANGE_Y - T / 2, 0)))
    base = base.union(flange)
    rear = (cq.Workplane("XY").box(2 * WALL_X - 0.3, T, REAR_WALL_H,
                                   centered=(True, True, False))
            .translate((0, PED_D / 2 - T / 2, 0)))
    rear = rear.cut(cq.Workplane("XZ").cylinder(3 * T, 0.3 * 10,
                                                centered=True)
                    .translate((0, PED_D / 2 - T / 2, WIRE_HOLE_Z)))
    base = base.union(rear)
    base = base.cut(cq.Workplane("YZ").cylinder(90, PIN_D / 2, centered=True)
                    .translate((0, PIN_Y, PIN_Z)))
    # quiet microswitch body + lever (visual)
    sw = (cq.Workplane("XY").box(20.0, 10.0, 6.5, centered=(True, True, False))
          .translate((SW_XY[0], SW_XY[1], T)))
    sw = sw.union(cq.Workplane("XY").box(16.0, 1.0, 0.8,
                                         centered=(True, True, False))
                  .rotate((0, SW_XY[1], T + 6.5), (1, 0, 0), 0)
                  .translate((SW_XY[0] - 1, SW_XY[1] - 4.0, T + 6.5)))
    for sx in (-1, 1):
        for sy in (-1, 1):
            base = base.cut(cq.Workplane("XY").cylinder(T, 1.7,
                            centered=(True, True, False))
                            .translate((sx * MOUNT_W / 2, sy * MOUNT_D / 2, 0)))
    plate = (cq.Workplane("XY").box(PED_W, PLATE_D, T,
                                    centered=(True, True, False))
             .translate((0, 0, PED_H - T)))
    for sx in (-1, 1):
        plate = plate.union(
            cq.Workplane("XY").box(T, PLATE_D, SKIRT_H,
                                   centered=(True, True, False))
            .translate((sx * SKIRT_X, 0, PED_H - T - SKIRT_H)))
    plate = plate.union(
        cq.Workplane("XY").box(PED_W, T, LIP_H, centered=(True, True, False))
        .translate((0, -PLATE_D / 2 - T / 2, PED_H - T - LIP_H)))
    plate = plate.union(
        cq.Workplane("XY").box(PED_W - 3.0, T, 12.0,
                               centered=(True, True, False))
        .translate((0, PLATE_D / 2 + T / 2, PED_H - T - 12.0)))
    for sx in (-1, 1):
        plate = plate.union(
            cq.Workplane("XY").box(EAR_W, EAR_Y[1] - EAR_Y[0], T,
                                   centered=(True, True, False))
            .translate((sx * (SKIRT_X + T / 2 + EAR_W / 2),
                        (EAR_Y[0] + EAR_Y[1]) / 2, EAR_Z - T)))
    plate = plate.cut(cq.Workplane("YZ").cylinder(90, PIN_D / 2, centered=True)
                      .translate((0, PIN_Y, PIN_Z)))
    pin = (cq.Workplane("YZ").cylinder(6, 3.2, centered=True)
           .translate((-SKIRT_X - 1.2, PIN_Y, PIN_Z)))
    pin = pin.union(cq.Workplane("YZ").cylinder(6, 3.2, centered=True)
                    .translate((SKIRT_X + 1.2, PIN_Y, PIN_Z)))
    assy = cq.Assembly()
    assy.add(base.val(), name="base", color=cq.Color(0.12, 0.12, 0.12))
    assy.add(plate.val(), name="plate", color=cq.Color(0.15, 0.15, 0.15))
    assy.add(pin.val(), name="rivets", color=cq.Color(0.6, 0.6, 0.65))
    assy.add(sw.val(), name="microswitch", color=cq.Color(0.45, 0.45, 0.48))
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
    # up-stop = the faceplate: ear top + 0.5 tape must meet the lid underside
    lid_under = 15.0 - 2.0
    assert abs((EAR_Z + 0.5) - lid_under) < 0.05, "ear/tape vs lid underside"
    ear_span = 2 * (SKIRT_X + T + EAR_W)
    assert ear_span > SLOT_W + 2.0, "ears must overlap under the faceplate"
    assert FLANGE_H <= 13.5, "flange pokes through the faceplate slot"
    # closed body: the BASE box (flange + rear wall) is the outer shell; the
    # moving lip / rear skirt planes tuck INSIDE it with >=1mm static gap
    lip_outer = PLATE_D / 2 + T            # lip plane outer face
    flange_inner = PED_D / 2 - T           # flange plane inner face
    assert flange_inner - lip_outer >= 1.0, "lip fouls the front flange"
    assert flange_inner - lip_outer >= 1.0, "rear skirt fouls the rear wall"
    assert PED_D <= SLOT_D - 2.0 and PED_W <= SLOT_W - 2.0, \
        "base box must pass the faceplate slot"


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
