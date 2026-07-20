#!/usr/bin/env python3
"""
VAMP silent footswitch -- printable replacement for the 10 purchased ASP-1s.

SILENCE STRATEGY (the whole point):
  * sensing = REED SWITCH + magnet: contactless (zero switch clack), fully
    passive 2-wire -> reads as a plain closure on the main board's existing
    2-pin JST footswitch inputs. No board or harness changes.
  * BOTH travel stops land on silicone: Ø8 x 2.2 adhesive bumpons in printed
    seats on the base rim (down-stop -- the plate meets the body's borders on
    rubber, never plastic), and a silicone/EPDM M3 washer under the retention
    screw head (up-stop, absorbs the spring return).
  * return spring is CAPTIVE on the retention screw inside greased pockets --
    no twang, no wander.
  * hinge = printed knuckles + 3 mm steel pin (or a length of 3 mm filament),
    snug bore, greased.

ENVELOPE = the console's ASP1_* placeholder (75 x 100 x 25, foot-plate proud
10 mm through the 78 x 103 faceplate slot) so the faceplate, pedestals, pads
and the whole fab package are untouched -- and the pedal dims become
design-controlled instead of PROVISIONAL-pending-purchase.

Mounting: 4x M3 down into the printed pedestal's EXISTING top heat-set
inserts (ASP1_MOUNT 55 x 80 pattern in vamp_enclosure.py).

FEEL/CALIBRATION KNOBS (hardware is never the ideal on paper):
  * rest height / preload  = how far you thread the M3 retention screw.
  * actuation point        = MAGNET_FACE_Z (post length) -- shim the magnet
    pocket or reprint the plate; reed AT/RT varies unit to unit.  # TUNE
  * feel                   = SPRING_RATE spec.                     # TUNE

BOM per pedal (x10 per console):
  1x reed switch, KSK-1A66 / MKA-14103 class (glass 2.3Ø x ~14 mm, NO form-C)
  1x magnet Ø5 x 2 N35 (press-fit)
  1x compression spring Ø10 x 20 free, ~1.5 N/mm            # TUNE feel
  1x M3 x 20 pan/button screw + silicone or EPDM M3 washer (up-stop)
  1x M3 heat-set insert (std 5.7 x 4.6) in the spring boss
  4x M3 x 12 (base -> pedestal inserts)
  4x Ø8 x 2.2 self-adhesive silicone bumpons (3M SJ5312 class)
  1x 3 mm steel rod / filament, 58 mm (hinge pin)
  1x 2-wire JST-XH pigtail soldered to the reed

Run:  ../enclosure/.venv/bin/python silent_pedal.py   -> ./out
"""
from __future__ import annotations
import os
import math
import cadquery as cq

# ---------------------------------------------------------------- envelope
PED_W, PED_D, PED_H = 75.0, 100.0, 25.0   # match ASP1_W/D/H in vamp_enclosure
MOUNT_W, MOUNT_D = 55.0, 80.0             # = ASP1_MOUNT pedestal insert pattern
SLOT_W, SLOT_D = 78.0, 103.0              # faceplate slot the plate moves in

# ---------------------------------------------------------------- base
WALL = 2.5
FLOOR = 3.0
BASE_H = 12.0
BUMP_D, BUMP_H, BUMP_SEAT = 8.0, 2.2, 0.8   # Ø8x2.2 bumpon, seated 0.8 deep
BUMP_BOSS_TOP = 15.0                        # boss top -> silicone face 16.4
BUMP_XY = [(-26.0, -34.0), (26.0, -34.0), (-26.0, 20.0), (26.0, 20.0)]

# ---------------------------------------------------------------- hinge
HINGE_Y = 44.0            # pin centre, rear
HINGE_Z = 19.0
TOWER_W, TOWER_D = 8.0, 10.0
TOWER_X = 20.0            # tower centres at +-20
PIN_D = 3.2               # 3mm pin, printed-snug

# ---------------------------------------------------------------- action
SCREW_XY = (0.0, -38.0)   # retention screw / spring column
SPRING_OD = 10.0
REED_XY = (14.0, -38.0)   # reed channel + magnet post centre
REED_SLOT = (3.4, 17.0, 2.0)          # w, l, depth into floor top
MAGNET_D, MAGNET_T = 5.0, 2.0
MAGNET_FACE_Z = 10.5      # magnet face height at REST -> ~4 mm gap when
                          # pressed = reed closes.               # TUNE
PLATE_T = 4.0
PLATE_TOP = PED_H         # 25: pad glues on top, proud height unchanged


def base():
    b = (cq.Workplane("XY").box(PED_W, PED_D, BASE_H,
                                centered=(True, True, False))
         .faces(">Z").shell(-WALL))                      # open-top tray
    # put the floor back to FLOOR thick (shell leaves WALL-thick floor)
    b = b.union(cq.Workplane("XY").box(PED_W - 2*WALL, PED_D - 2*WALL, FLOOR,
                                       centered=(True, True, False)))
    # bumpon bosses fused to the side walls (the plate lands on silicone)
    for x, y in BUMP_XY:
        b = b.union(cq.Workplane("XY").cylinder(BUMP_BOSS_TOP, 6.0,
                    centered=(True, True, False)).translate((x, y, 0)))
        b = b.cut(cq.Workplane("XY").cylinder(BUMP_SEAT, BUMP_D/2 + 0.1,
                  centered=(True, True, False))
                  .translate((x, y, BUMP_BOSS_TOP - BUMP_SEAT)))
    # hinge towers
    for sx in (-1, 1):
        t = (cq.Workplane("XY").box(TOWER_W, TOWER_D, HINGE_Z + 2.0,
                                    centered=(True, True, False))
             .translate((sx*TOWER_X, HINGE_Y, 0)))
        b = b.union(t)
    b = b.cut(cq.Workplane("YZ").cylinder(PED_W, PIN_D/2, centered=True)
              .rotate((0, 0, 0), (0, 1, 0), 90)
              .translate((0, HINGE_Y, HINGE_Z)))
    # spring boss + M3 heat-set pocket (insert from the top)
    sb = (cq.Workplane("XY").cylinder(7.0, 7.5, centered=(True, True, False))
          .translate((SCREW_XY[0], SCREW_XY[1], 0)))
    b = b.union(sb)
    b = b.cut(cq.Workplane("XY").cylinder(6.4, 2.0, centered=(True, True, False))
              .translate((SCREW_XY[0], SCREW_XY[1], 7.0 - 6.4)))
    # reed channel + wire groove to the +X wall notch
    rw, rl, rd = REED_SLOT
    b = b.cut(cq.Workplane("XY").box(rw, rl, rd, centered=(True, True, False))
              .translate((REED_XY[0], REED_XY[1], FLOOR - rd)))
    b = b.cut(cq.Workplane("XY").box(PED_W/2 - REED_XY[0], 3.0, rd,
                                     centered=(False, True, False))
              .translate((REED_XY[0], REED_XY[1], FLOOR - rd)))
    b = b.cut(cq.Workplane("XY").box(WALL + 2.0, 4.0, 5.0,
                                     centered=(False, True, False))
              .translate((PED_W/2 - WALL - 1.0, REED_XY[1], 0)))
    # 4x M3 clearance + counterbore down into the pedestal inserts
    for sx in (-1, 1):
        for sy in (-1, 1):
            x, y = sx*MOUNT_W/2, sy*MOUNT_D/2
            b = b.cut(cq.Workplane("XY").cylinder(FLOOR, 1.7,
                      centered=(True, True, False)).translate((x, y, 0)))
            b = b.cut(cq.Workplane("XY").cylinder(FLOOR - 1.2, 3.3,
                      centered=(True, True, False)).translate((x, y, 1.2)))
    return b


def plate():
    p = (cq.Workplane("XY").box(PED_W, PED_D, PLATE_T,
                                centered=(True, True, False))
         .translate((0, 0, PLATE_TOP - PLATE_T)))
    # rear notches around the towers + knuckles down to the pin
    for sx in (-1, 1):
        p = p.cut(cq.Workplane("XY").box(TOWER_W + 1.0, TOWER_D + 1.0, PLATE_T,
                                         centered=(True, True, False))
                  .translate((sx*TOWER_X, HINGE_Y, PLATE_TOP - PLATE_T)))
        k = (cq.Workplane("XY").box(8.0, TOWER_D, PLATE_TOP - PLATE_T - (HINGE_Z - 2.0),
                                    centered=(True, True, False))
             .translate((sx*11.0, HINGE_Y, HINGE_Z - 2.0)))
        p = p.union(k)
    p = p.cut(cq.Workplane("YZ").cylinder(PED_W, PIN_D/2, centered=True)
              .rotate((0, 0, 0), (0, 1, 0), 90)
              .translate((0, HINGE_Y, HINGE_Z)))
    # retention screw: Ø4.5 clearance + Ø9 counterbore (silicone washer seat)
    p = p.cut(cq.Workplane("XY").cylinder(PLATE_T, 2.25,
              centered=(True, True, False))
              .translate((SCREW_XY[0], SCREW_XY[1], PLATE_TOP - PLATE_T)))
    p = p.cut(cq.Workplane("XY").cylinder(2.5, 4.5, centered=(True, True, False))
              .translate((SCREW_XY[0], SCREW_XY[1], PLATE_TOP - 2.5)))
    # spring upper seat (shallow ring recess in the underside)
    p = p.cut(cq.Workplane("XY").cylinder(1.5, SPRING_OD/2 + 0.3,
              centered=(True, True, False))
              .translate((SCREW_XY[0], SCREW_XY[1], PLATE_TOP - PLATE_T)))
    # magnet post above the reed
    post_h = PLATE_TOP - PLATE_T - MAGNET_FACE_Z
    post = (cq.Workplane("XY").cylinder(post_h, 4.5,
            centered=(True, True, False))
            .translate((REED_XY[0], REED_XY[1], MAGNET_FACE_Z)))
    p = p.union(post)
    p = p.cut(cq.Workplane("XY").cylinder(MAGNET_T + 0.4, MAGNET_D/2 + 0.15,
              centered=(True, True, False))
              .translate((REED_XY[0], REED_XY[1], MAGNET_FACE_Z)))
    return p


def checks(b, p):
    bb, pb = b.val().BoundingBox(), p.val().BoundingBox()
    assert bb.xlen <= PED_W + 0.2 and bb.ylen <= PED_D + 0.2, "base oversize"
    assert pb.zmax <= PED_H + 0.01, "plate above envelope"
    assert pb.xlen <= SLOT_W - 2.8 and pb.ylen <= SLOT_D - 2.8, \
        "plate won't clear the faceplate slot"
    # travel: front bumpon face vs plate underside, projected to the toe
    stop_z = BUMP_BOSS_TOP - BUMP_SEAT + BUMP_H
    drop = (PLATE_TOP - PLATE_T) - stop_z
    toe = drop * (HINGE_Y + PED_D/2) / (HINGE_Y - BUMP_XY[0][1])
    # magnet gap at rest and pressed (at the reed x/y)
    drop_m = drop * (HINGE_Y - REED_XY[1]) / (HINGE_Y - BUMP_XY[0][1])
    gap_rest = MAGNET_FACE_Z - FLOOR
    gap_press = gap_rest - drop_m
    print("toe travel %.1f mm | magnet gap rest %.1f -> pressed %.1f mm"
          % (toe, gap_rest, gap_press))
    assert 3.5 <= toe <= 7.0, "toe travel outside the quiet/positive range"
    assert gap_press <= 4.5, "magnet never gets close enough to close the reed"
    assert gap_rest >= 6.5, "reed may stay closed at rest (release margin)"


def export():
    out = os.path.join(os.path.dirname(__file__), "out")
    os.makedirs(out, exist_ok=True)
    b, p = base(), plate()
    checks(b, p)
    pin = (cq.Workplane("YZ").cylinder(58.0, 1.5, centered=True)
           .rotate((0, 0, 0), (0, 1, 0), 90).translate((0, HINGE_Y, HINGE_Z)))
    for name, solid in (("silent_pedal_base", b), ("silent_pedal_plate", p)):
        cq.exporters.export(solid, os.path.join(out, name + ".step"))
        cq.exporters.export(solid, os.path.join(out, name + ".stl"))
    assy = cq.Assembly()
    assy.add(b.val(), name="base", color=cq.Color(0.15, 0.15, 0.15))
    assy.add(p.val(), name="plate", color=cq.Color(0.22, 0.22, 0.22))
    assy.add(pin.val(), name="pin", color=cq.Color(0.6, 0.6, 0.65))
    assy.save(os.path.join(out, "silent_pedal_assy.step"))
    for name, d in (("top", (0, 0, 1)), ("iso", (1, -1, 0.8))):
        cq.exporters.export(
            b.union(p), os.path.join(out, f"silent_pedal_{name}.svg"),
            opt={"projectionDir": d, "showAxes": False,
                 "strokeWidth": 0.4, "width": 640, "height": 480})
    print("wrote base/plate (.step/.stl) + assy + previews in", out)


if __name__ == "__main__":
    export()
