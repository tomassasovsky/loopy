#!/usr/bin/env python3
"""
VAMP silent footswitch v4 -- SHEET METAL CLAMSHELL, sustain-pedal
construction (Artesia / M-Audio reference).

Two folded 2.0 mm 5052 parts per pedal (x10), same laser+bend process as
the enclosure (flats ride in vamp_sheetmetal.zip):

  BASE  : shallow tray, floor + 4 walls UP (enclosure corner pattern).
          Front wall 18 mm = the silicone-taped DOWN-STOP; side walls
          16 mm carry the hinge rivet bores; rear wall 16 mm has the
          wire exit hole.
  PLATE : INVERTED TRAY -- the whole top. Treadle (96 x 71, exactly the
          cast pad's footprint -> the fold shoulders read as the metal
          rim around the pad, like the reference) + skirts folded DOWN
          on ALL FOUR SIDES, hanging OUTSIDE the base walls. The
          clamshell overlap hides the interior at every travel position
          -- from outside it looks exactly like a commercial sustain
          pedal (minus the polarity switch, which we don't need).

Mechanism:
  * hinge: 2x M4 SHOULDER SCREWS (O5 x 4 shoulder) from outside through
    the skirt (O5.1 pivot bore) + 1 mm washer, threaded into PEM M4
    clinch nuts pressed on the wall's INNER face before the clamshell
    closes -- single-side final assembly, and the shoulder leaves a
    controlled 0.5 mm float so the pivot can never clamp solid. The
    screw heads show on the sides exactly like the reference.
  * return: compression spring O10 on the floor seat, front-centre.
  * UP-stop / retention: GEOMETRIC, no screw. The REAR skirt is cut
    longer than the others -- its bottom edge rests on SILICONE TAPE on
    the pedestal deck, preloaded there by the spring (that IS the rest
    position; rest height = skirt length + tape, shim tape to trim).
    Lifting the front only digs the rear edge harder into the deck, so
    the plate is captive; pressing lifts the rear edge ~0.5 mm.
  * DOWN-stop: treadle underside lands on SILICONE TAPE on the front
    wall top -- full-width contact (travel 4.0 mm there, ~4.1 at the
    toe). Side/rear walls are 2 mm lower and never touch.
  * switch: QUIET lever microswitch (Cherry DB3 / ZF D4 class, 2-wire
    NO) on the floor -- plain closure into the board's JST inputs.
  * wire: O6 hole in the rear wall (z 11) -- hidden behind the rear
    skirt; the pigtail drops down the 2 mm gap and runs out under the
    skirt's bottom edge, like the reference's rear cable exit.

SILENCE: contact-quiet microswitch; both stops land on silicone tape
(front wall top going down, pedestal deck at the rear coming back up,
both at tiny lever arms); spring seated on a dab of RTV in the marked
seat; greased shoulder pivots.

ENVELOPE: base 70.8 x 93.8 inside the console's 75 x 100 station; plate
skirts overhang to 76.8 x 101.8, proud through the faceplate slot
(FSW_SLOT = footprint + 5 -> 80 x 105, 1.6 mm running clearance).
Mounts 4x M3 into the pedestal inserts (ASP1_MOUNT 55 x 80).

TUNE: spring spec (feel), retention thread depth (rest height), tape
thickness (down-stop travel), switch lever bend (actuation point).

BOM per pedal (x10): quiet lever microswitch; spring O10 x 25 free ~1.5 N/mm
(4 mm / ~6 N preload in the 21 mm cavity, solid height < 15);
2x M4 shoulder screw (O5 x 4) + O5 x 1 washer + PEM CLS-M4 (pivots);
4x M3 x 6 (pedestal -- the insert pilots are shallow); silicone tape (front wall top + rear deck
strip); RTV dab (spring seat); O6 grommet optional; JST-XH pigtail.

Flat offsets use the MEASURED fold model (CenterFoldBendLinePosition:
folded extent = drawn + DED90/2 ~ 1.9 mm; plane mid-line lands 1.9
beyond the drawn line), verified against the native sheet-metal build.
A formal dev_deduct pass is still owed before fab.

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
MOUNT_W, MOUNT_D = 52.0, 72.0             # ASP1_MOUNT pedestal inserts
                                          # (pulled clear of the bend bands)
SLOT_W, SLOT_D = PED_W + 5.0, PED_D + 5.0  # faceplate slot (clamshell)

T = 2.0
RI, KF = 2.0, 0.33
BA90 = math.pi / 2.0 * (RI + KF * T)
DED90 = 2.0 * (RI + T) - BA90
# MEASURED fold model (CenterFoldBendLinePosition, verified in Fusion):
# folded extent past the fold line = drawn length + EMP; the folded
# plane's mid-line lands EMP beyond the drawn line.
EMP = DED90 / 2.0                         # ~1.9 mm

# ---------------------------------------------------------------- base (v4)
BWALL_X = 32.0                            # side wall folds: skirt/wall gap
                                          # 1.5 = washer 1.0 + 0.5 float
BWALL_Y = 44.0                            # front/rear folds (planes ~+-45.9)
H_FRONT = 18.0                            # front wall: taped down-stop
H_SIDE = 17.0                             # side walls: hinge pivots
H_REAR = 16.0                             # rear wall: wire exit
PIN_Y, PIN_Z = 40.0, 8.0                  # hinge pivot centre: low enough
                                          # that the screw head (O7.5 x 3.2)
                                          # passes UNDER the faceplate edge
PIN_WALL_D = 5.4                          # PEM CLS-M4 mounting hole
PIN_SKIRT_D = 5.1                         # pivot bore on the O5 shoulder
SW_HOLES = 22.2                           # microswitch mount pitch (M2.3)
SW_XY = (0.0, -26.0)
SPRING_XY = (0.0, -38.0)                  # spring seat / retention screw axis
WIRE_Z = 11.0                             # wire hole centre height, rear wall
TAPE_T = 1.0                              # silicone tape thickness

# ---------------------------------------------------------------- plate (v4)
TREAD_W, TREAD_D = 71.0, 96.0             # treadle = the pad footprint
SKIRT_BOT = 6.0                           # side/front skirt bottom at rest
HINGE_BOT = 3.5                           # side skirts step lower at the
HINGE_Y = (34.0, 46.0)                    # hinge zone so the low bore keeps
                                          # its edge margin (rear = no press)
REAR_BOT = 1.0                            # rear skirt: rests on deck tape --
                                          # the geometric up-stop/retention


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


def _tray(msp, fx, fy, dev_side, dev_front, dev_rear, side_step=None):
    """Shared tray outline: full-span folds meeting in O6 corner reliefs
    (the proven enclosure pattern), kerf-trimmed front/rear flaps.
    side_step=(sy0, sy1, extra): the side flaps run `extra` deeper over
    that y-range (the plate's hinge zone)."""
    L, R = -fx, fx
    y0, y1 = -fy, fy
    K = 0.15

    def side(xs, sgn):
        if not side_step:
            return [(xs + sgn * dev_side, y0), (xs + sgn * dev_side, y1)]
        sy0, sy1, ex = side_step
        return [(xs + sgn * dev_side, y0), (xs + sgn * dev_side, sy0),
                (xs + sgn * (dev_side + ex), sy0),
                (xs + sgn * (dev_side + ex), sy1),
                (xs + sgn * dev_side, sy1), (xs + sgn * dev_side, y1)]

    pts = ([(L + K, y0), (L + K, y0 - dev_front), (R - K, y0 - dev_front),
            (R - K, y0), (R, y0)] + side(R, +1) +
           [(R, y1), (R - K, y1), (R - K, y1 + dev_rear),
            (L + K, y1 + dev_rear), (L + K, y1), (L, y1)] +
           list(reversed(side(L, -1))) + [(L, y0)])
    _poly(msp, pts, "CUT")
    for x in (L, R):
        _poly(msp, [(x, y0), (x, y1)], "BEND", closed=False)
    _poly(msp, [(L + K, y0), (R - K, y0)], "BEND", closed=False)
    _poly(msp, [(L + K, y1), (R - K, y1)], "BEND", closed=False)
    for cx, cy in ((L, y0), (R, y0), (L, y1), (R, y1)):
        _circle(msp, cx, cy, 6.0)


def dxf_base(path):
    doc = _doc(); msp = doc.modelspace()
    _tray(msp, BWALL_X, BWALL_Y,
          H_SIDE - EMP, H_FRONT - EMP, H_REAR - EMP)
    for x in (BWALL_X + (PIN_Z - EMP), -BWALL_X - (PIN_Z - EMP)):
        _circle(msp, x, PIN_Y, PIN_WALL_D)                # PEM CLS-M4 holes
    for sx in (-1, 1):
        for sy in (-1, 1):
            _circle(msp, sx * MOUNT_W / 2.0, sy * MOUNT_D / 2.0, 3.4)
    for sx in (-1, 1):
        _circle(msp, SW_XY[0] + sx * SW_HOLES / 2.0, SW_XY[1], 2.4)
    _circle(msp, SPRING_XY[0], SPRING_XY[1], 10.0, "ENGRAVE")   # spring seat
    _circle(msp, 0.0, BWALL_Y + (WIRE_Z - EMP), 6.0)      # wire exit, rear
    _poly(msp, [(-BWALL_X + 4, -BWALL_Y - (H_FRONT - EMP) / 2.0),
                (BWALL_X - 4, -BWALL_Y - (H_FRONT - EMP) / 2.0)],
          "ENGRAVE", closed=False)                        # tape zone
    msp.add_text("VAMP PEDAL BASE v4  2.0mm  x10  tray: 4 walls UP 90; "
                 "silicone TAPE full width on the FRONT (18mm) wall top; "
                 "PEM CLS-M4 press on the INNER face at the O5.4 holes; "
                 "wire out the rear O6 hole",
                 dxfattribs={"layer": "NOTE", "height": 5}).set_placement(
                 (-BWALL_X - (H_SIDE - EMP), BWALL_Y + (H_REAR - EMP) + 6))
    doc.saveas(path)


def dxf_plate(path):
    doc = _doc(); msp = doc.modelspace()
    dev = (PED_H - SKIRT_BOT) - EMP                       # skirt: bottom z 6
    # (folded extents measure from the DRAWN top face at z25, not the
    # underside -- the v3 build proved this the hard way)
    dev_r = (PED_H - REAR_BOT) - EMP                      # rear: bottom z 1
    step = (PED_H - HINGE_BOT) - EMP - dev                # hinge-zone step
    _tray(msp, TREAD_W / 2.0, TREAD_D / 2.0, dev, dev, dev_r,
          side_step=(HINGE_Y[0], HINGE_Y[1], step))
    bore_off = (PED_H - PIN_Z) - EMP                      # bore: z = PIN_Z
    for sx in (-1, 1):
        _circle(msp, sx * (TREAD_W / 2.0 + bore_off), PIN_Y, PIN_SKIRT_D)
    msp.add_text("VAMP PEDAL PLATE v4  2.0mm  x10  inverted tray: 4 skirts "
                 "DOWN 90, they wrap OUTSIDE the base walls (clamshell); "
                 "asp1_pad glues on top (hides the M4 nyloc + washer)",
                 dxfattribs={"layer": "NOTE", "height": 5}).set_placement(
                 (-TREAD_W / 2.0 - dev, TREAD_D / 2.0 + dev + 6))
    doc.saveas(path)


def build_step():
    """Idealized folded assembly STEP (visual reference; the native folds
    live in the Fusion doc)."""
    import cadquery as cq
    base = cq.Workplane("XY").box(2 * BWALL_X + 2 * T, 2 * BWALL_Y + 2 * T,
                                  T, centered=(True, True, False))
    for sx in (-1, 1):
        base = base.union(
            cq.Workplane("XY").box(T, 2 * BWALL_Y, H_SIDE,
                                   centered=(True, True, False))
            .translate((sx * (BWALL_X + EMP), 0, 0)))
    for sy, h in ((-1, H_FRONT), (1, H_REAR)):
        base = base.union(
            cq.Workplane("XY").box(2 * BWALL_X - 0.3, T, h,
                                   centered=(True, True, False))
            .translate((0, sy * (BWALL_Y + EMP), 0)))
    base = base.cut(cq.Workplane("YZ").cylinder(90, PIN_WALL_D / 2,
                                                centered=True)
                    .translate((0, PIN_Y, PIN_Z)))
    plate = (cq.Workplane("XY").box(TREAD_W, TREAD_D, T,
                                    centered=(True, True, False))
             .translate((0, 0, PED_H - T)))
    sk = PED_H - T - SKIRT_BOT
    for sx in (-1, 1):
        plate = plate.union(
            cq.Workplane("XY").box(T, TREAD_D, sk,
                                   centered=(True, True, False))
            .translate((sx * (TREAD_W / 2 + EMP), 0, SKIRT_BOT)))
    for sy, bot in ((-1, SKIRT_BOT), (1, REAR_BOT)):
        plate = plate.union(
            cq.Workplane("XY").box(TREAD_W - 0.3, T, PED_H - T - bot,
                                   centered=(True, True, False))
            .translate((0, sy * (TREAD_D / 2 + EMP), bot)))
    plate = plate.cut(cq.Workplane("YZ").cylinder(90, PIN_SKIRT_D / 2,
                                                  centered=True)
                      .translate((0, PIN_Y, PIN_Z)))
    assy = cq.Assembly()
    assy.add(base.val(), name="base", color=cq.Color(0.12, 0.12, 0.12))
    assy.add(plate.val(), name="plate", color=cq.Color(0.15, 0.15, 0.15))
    assy.save(os.path.join(OUT, "silent_pedal_assy.step"))


def checks():
    under = PED_H - T                                 # treadle underside
    hinge_arm = PIN_Y + BWALL_Y + EMP                 # pin to front wall
    travel = under - (H_FRONT + TAPE_T)               # at the front wall
    assert 3.0 <= travel <= 5.0, "down-stop travel out of range"
    toe = travel * (PIN_Y + TREAD_D / 2.0 + EMP + T) / hinge_arm
    # clamshell fits: skirts inside the slot, base inside the envelope
    sk_w = 2 * (TREAD_W / 2.0 + EMP + T / 2)
    sk_d = 2 * (TREAD_D / 2.0 + EMP + T / 2)
    assert sk_w <= SLOT_W - 3.0, "side skirts foul the slot"
    assert sk_d <= SLOT_D - 3.0, "front/rear skirts foul the slot"
    assert 2 * (BWALL_X + EMP + T / 2) <= PED_W, "base wider than envelope"
    assert 2 * (BWALL_Y + EMP + T / 2) <= PED_D, "base deeper than envelope"
    # skirts hang OUTSIDE the walls with the designed gaps
    gap_side = (TREAD_W / 2.0 + EMP - T / 2) - (BWALL_X + EMP + T / 2)
    assert 1.3 <= gap_side <= 1.8, \
        "hinge gap must fit washer 1.0 + ~0.5 float + powder coat"
    gap_rear = (TREAD_D / 2.0 + EMP - T / 2) - (BWALL_Y + EMP + T / 2)
    assert gap_rear >= 1.5, "rear skirt too close to the rear wall"
    # skirt bottoms stay above the pedestal deck at full press
    skirt_pressed = SKIRT_BOT - travel * (PIN_Y + TREAD_D / 2.0 + EMP) \
        / hinge_arm
    assert skirt_pressed > 1.0, "front skirt hits the pedestal deck"
    # rear-skirt up-stop: rests on deck tape at z REAR_BOT (spring preload
    # reacts there); pressing LIFTS it, arm is behind the pivot
    rear_arm = (TREAD_D / 2.0 + EMP) - PIN_Y
    assert rear_arm > 5.0, "rear skirt too close to the pivot to act as stop"
    assert abs(REAR_BOT - TAPE_T) < 0.6, "rear skirt / deck tape mismatch"
    rise = travel * rear_arm / hinge_arm
    assert rise < 1.0, "rear skirt kicks up visibly when pressed"
    # side/rear walls never touch the descending treadle
    assert under - travel * (PIN_Y + BWALL_Y) / hinge_arm > H_SIDE + 1.0, \
        "side walls in the travel path"
    # bore + hole edge margins in the flats
    dev = (PED_H - SKIRT_BOT) - EMP
    bore_off = (PED_H - PIN_Z) - EMP
    assert PIN_Z + 3.75 <= 12.0, \
        "pivot screw head reaches the faceplate band (O7.5 head)"
    hinge_dev = (PED_H - HINGE_BOT) - EMP
    assert hinge_dev - bore_off - PIN_SKIRT_D / 2 >= 1.5, \
        "skirt bore too near the stepped edge"
    assert HINGE_Y[0] < PIN_Y - 4.0 and HINGE_Y[1] > PIN_Y + 4.0, \
        "hinge step does not span the bore"
    # step's front end is ahead of the pivot -> it presses DOWN a little
    step_drop = travel * (PIN_Y - HINGE_Y[0]) / hinge_arm
    assert HINGE_BOT - step_drop > 1.0, "hinge step hits the deck pressed"
    assert bore_off - PIN_SKIRT_D / 2 >= 6.0, "skirt bore in the bend band"
    assert H_SIDE - PIN_Z - PIN_WALL_D / 2 >= 1.5, \
        "PEM hole too near wall top"
    # shoulder stack: skirt 2 + washer 1 + float = shoulder 4
    assert abs((T + 1.0 + 0.5) - 3.5) < 0.6, "shoulder length mismatch"
    assert (WIRE_Z - EMP) - 3.0 >= 6.0, "wire hole in the bend band"
    assert H_REAR - EMP - (WIRE_Z - EMP) - 3.0 >= 1.5, \
        "wire hole too near wall top"
    assert BWALL_Y - MOUNT_D / 2.0 - 1.7 >= 4.0, "mount holes in bend band (D)"
    assert BWALL_X - MOUNT_W / 2.0 - 1.7 >= 4.0, "mount holes in bend band (W)"
    print("travel %.1f mm at the front wall / %.1f at the toe | "
          "clamshell %.1f x %.1f in slot %.0f x %.0f | pin (y%.0f z%.0f) | "
          "skirt bottom %.0f -> %.1f pressed"
          % (travel, toe, sk_w, sk_d, SLOT_W, SLOT_D, PIN_Y, PIN_Z,
             SKIRT_BOT, skirt_pressed))


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
