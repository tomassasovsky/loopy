"""VAMP — parametric sheet-metal enclosure for the loopy Pi loopstation.

Generates a **manufacturing package** for a wedge-shaped floor console modelled on
the "Chewie II" / Sonnit reference (850 x 465 x 100 mm, top sloping toward the
player), housing this repo's standalone build: a Raspberry Pi 4/5 running loopy,
the loopy_pi_main board, ten foot pedals, the EC11 encoder + diffused LED ring,
through-hole indicator LEDs and a 7" + 16" touchscreen pair. Branded **VAMP**.

Construction (see ../loopy_vamp_enclosure_design.md and
../../docs/plan/2026-06-27-feat-vamp-enclosure-rework-plan.md):

  WELDED SHELL (one rigid body)             REMOVABLE / INSERT PARTS
  - faceplate (sloped top, all cutouts)     - bottom plate (bolted, vented)
  - front wall (45) + bottom flange         - 10x inner pedal platform (spot-welded)
  - rear wall (100) + I/O + vents + flange  - 2x screen-retention bracket
  - 2x side panel + bottom flange

Foot controls = ten WHOLE Artesia ASP-1 pedals (100x75x25 mm) standing on the
welded inner platforms, foot-plates protruding through ~75x100 mm slots. No
top-face fasteners; pedal wiring stays internal. Service = unbolt the bottom plate.

Geometry is validated by an **assertion suite** (`_check()`) run before any output,
so "the generator runs" means the geometry is valid (width budget, no overlapping
cutouts, platform head-room, screen depth, vent free-area, bezel overlap).

Outputs (./out, mm): STEP (assembly + per-part), DXF flat patterns
(CUT/BEND/ENGRAVE/WELD/VENT layers), PDF drawing sheets.

Run with the bundled venv (cadquery + ezdxf + matplotlib):
    .venv/bin/python vamp_enclosure.py            # check + STEP + DXF + PDF
    .venv/bin/python vamp_enclosure.py --report   # report + checks only
    .venv/bin/python vamp_enclosure.py --no-step   # DXF + PDF only
"""
from __future__ import annotations

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")

# ===========================================================================
# PARAMETERS — edit here; everything downstream is derived
# ===========================================================================

W        = 850.0     # overall width
D        = 465.0     # overall depth (front lip -> rear wall)
H_REAR   = 100.0     # rear wall height (tall end, behind the main screen)
H_FRONT  = 45.0      # front lip height (low end, nearest the player)

T        = 2.0       # sheet thickness (2.0 mm 5052-H32 aluminium)
RI       = 2.0       # inside bend radius (= T, safe for 5052)
KF       = 0.33      # K-factor for bend-allowance development
FLANGE   = 18.0      # bottom return-flange depth (PEM-nut land for the bottom plate)

# --- foot pedals: whole Artesia ASP-1 (100 x 75 x 25 mm), PROVISIONAL ---------
# Measure a real ASP-1 before cutting metal. Mounted 75 across the panel (u),
# 100 front-to-back (v), 25 body height into -Z.
ASP1_W, ASP1_D, ASP1_H = 75.0, 100.0, 25.0    # pedal footprint W(u) x D(v) x H(z)
FSW_SLOT_W = ASP1_W + 3.0     # slot clearance around the foot-plate (u)
FSW_SLOT_D = ASP1_D + 3.0     # slot clearance (v)
FSW_V      = 80.0             # front-row centre line (v)
FSW_PITCH  = 80.0             # centre-to-centre across the row
FOOTPLATE_PROUD = 2.0         # how far the foot-plate sits above the panel
PLATFORM_MARGIN = 6.0         # platform shelf overhang past the pedal footprint
PLATFORM_LEG_W  = 14.0        # weld-tab / leg width

# --- screens (capacitive touch, mounted from BEHIND; aperture < bezel) --------
BIG_BEZEL  = (355.0, 223.0)   # 16" module glass/bezel (ViewSonic TD1655 class)
BIG_W, BIG_H     = 350.0, 199.0   # 16" aperture (active area, bezel overlaps)
BIG_DEPTH  = 18.0             # module depth behind the panel (15 mm + cable slack)
SMALL_BEZEL = (165.0, 100.0)  # 7" module outline
SMALL_W, SMALL_H = 156.0, 88.0    # 7" aperture (active ~154x86)
SMALL_DEPTH = 30.0            # 7" module + DSI ribbon depth

# --- LEDs / encoder -----------------------------------------------------------
D_LED     = 5.1      # 5 mm through-hole LED (cabled)
D_LEDBZ   = 8.0      # 5 mm LED + chrome bezel (power / mode)
D_ENC     = 7.0      # EC11 encoder bush
RING_OD   = 58.0     # diffused-annulus ring window OD (12 THT LEDs behind)
RING_ID   = 40.0     # ring window ID
N_IND     = 7        # indicator LEDs (loopy indicatorLeds[7])
IND_PITCH = 50.0     # indicator LED pitch

# --- rear I/O -----------------------------------------------------------------
D_BARREL  = 12.0     # 9 V DC barrel jack nut
D_PWRBTN  = 16.0     # power / shutdown button
D_FUSE    = 12.0     # panel fuse holder
D_GND     = 6.5      # M6 earth / bond stud

# --- ventilation / mounting ---------------------------------------------------
VENT_SLOT   = (40.0, 4.0)     # one louvre slot (l x w)
VENT_PITCH  = 9.0             # slot row pitch
VENT_FREE_AREA_MIN = 4000.0   # mm^2 minimum open area (bottom + rear), ~40 cm^2
STANDOFF_H  = 10.0            # min under-board gap (airflow under the Pi)
STANDOFF_PITCH = (58.0, 49.0) # Raspberry Pi mounting holes
D_FOOT    = 8.0      # rubber-foot fixing

# --- fasteners ----------------------------------------------------------------
D_M3      = 3.2      # M3 clearance (Pi/board standoffs)
D_M4      = 4.3      # M4 clearance (bottom plate -> shell)
PEM_M4    = 6.3      # PEM M4 clinch hole (DISTINCT from M4 clearance)
PEM_EDGE  = 8.0      # min PEM centre-to-edge distance
R_FILLET  = 3.0      # inside corner radius on rectangular cutouts

# ===========================================================================
# DERIVED GEOMETRY
# ===========================================================================

SLOPE_DROP  = H_REAR - H_FRONT
L_SLOPE     = math.hypot(D, SLOPE_DROP)
SLOPE_ANGLE = math.degrees(math.atan2(SLOPE_DROP, D))

def bend_allowance(angle_deg, t=T, ri=RI, k=KF):
    return math.radians(angle_deg) * (ri + k * t)

BA90 = bend_allowance(90.0)
FL   = FLANGE - (T + KF * T)          # flange flat length after bend deduction
FP_W = W - 2.0 * T                    # faceplate width (welded between the sides)
FP_V = L_SLOPE                        # faceplate length up the slope

def lid_top_z(v):
    """Z of the faceplate TOP surface at depth v (sloped wedge)."""
    return H_FRONT + SLOPE_DROP * (v / D)

def lid_under_z(v):
    """Z of the faceplate UNDERSIDE at depth v."""
    return lid_top_z(v) - T

# Platform height that lands the foot-plate flush+proud at the front row.
PLATFORM_H = lid_top_z(FSW_V) + FOOTPLATE_PROUD - ASP1_H

# ===========================================================================
# CUTOUT SCHEDULE  (faceplate local: u=0..FP_W L->R = player's left->right,
#                   v=0..FP_V front->rear)
# ===========================================================================

# Two pedal rows, faithful to the reference: a FRONT row of 8 (4 transport |
# 4 tracks, with a centre gap) and an upper CENTRE pair (CLEAR/BANK). Each pedal
# is a whole ASP-1 on a welded platform; a status LED sits directly ABOVE each
# (aligned in u). CLEAR/BANK ride centre so the 16" screen still fits depth-wise.
PEDAL_ROW1_V = 80.0      # front row centre
SCREEN_TOP_V = 445.0     # common TOP (rear) edge for both screens
S7_U         = 30.0      # 7" screen left edge
LED_GAP      = 16.0      # status-LED offset behind a pedal (toward rear)
# CLEAR/BANK sit so their BOTTOM (front) edge aligns with the 16" screen's bottom.
PEDAL_ROW2_V = (SCREEN_TOP_V - BIG_H) + FSW_SLOT_D / 2.0

# Front row of 8, EVENLY spaced across the faceplate (no 4+4 grouping).
_ROW1 = ["REC/PLAY", "STOP", "UNDO", "MODE", "TRACK1", "TRACK2", "TRACK3", "TRACK4"]
def _row1_u(i):
    return FP_W * (i + 0.5) / 8.0

# CLEAR/BANK ride row 2, aligned in u with UNDO (i=2) and MODE (i=3).
PEDALS = [(_ROW1[i], _row1_u(i), PEDAL_ROW1_V) for i in range(8)] + [
    ("CLEAR", _row1_u(2), PEDAL_ROW2_V), ("BANK", _row1_u(3), PEDAL_ROW2_V)]

# Only the four TRACK pedals carry a status LED (reference: track state).
def _has_led(label):
    return label.startswith("TRACK")

def platform_h(v):
    """Platform shelf height that lands the ASP-1 foot-plate flush+proud at depth v."""
    return lid_top_z(v) + FOOTPLATE_PROUD - ASP1_H

def faceplate_holes():
    """All faceplate features. Pedal slots have NO mounting holes (the pedals
    stand on internal welded platforms). u=player L->R, v=front->rear."""
    cuts, engr = [], []
    # --- 10 pedal slots (two rows); a status LED above the TRACK pedals only -
    for label, u, v in PEDALS:
        cuts.append({"kind": "rect", "u": u - FSW_SLOT_W/2, "v": v - FSW_SLOT_D/2,
                     "w": FSW_SLOT_W, "h": FSW_SLOT_D, "ref": label})
        engr.append({"u": u - 16, "v": v - FSW_SLOT_D/2 - 11, "h": 6.0, "s": label})
        if _has_led(label):
            cuts.append({"kind": "circle", "u": u, "v": v + FSW_SLOT_D/2 + LED_GAP,
                         "d": D_LED, "ref": label + "_LED"})
    # --- screens: top edges aligned on SCREEN_TOP_V ------------------------
    cuts.append({"kind": "rect", "u": S7_U,  "v": SCREEN_TOP_V - SMALL_H, "w": SMALL_W, "h": SMALL_H, "ref": "SCREEN_7IN"})
    cuts.append({"kind": "rect", "u": 460.0, "v": SCREEN_TOP_V - BIG_H,   "w": BIG_W,   "h": BIG_H,   "ref": "SCREEN_16IN"})
    # --- encoder + diffused ring on the vertical centre line of CLEAR/BANK, --
    #     sitting in the gap in FRONT of them (between the front row and CLEAR/BANK)
    enc_u = (_row1_u(2) + _row1_u(3)) / 2.0
    front_top = PEDAL_ROW1_V + FSW_SLOT_D / 2.0
    cb_bottom = PEDAL_ROW2_V - FSW_SLOT_D / 2.0
    enc_v = (front_top + cb_bottom) / 2.0
    cuts.append({"kind": "ring",   "u": enc_u, "v": enc_v, "od": RING_OD, "id": RING_ID, "ref": "RING"})
    cuts.append({"kind": "circle", "u": enc_u, "v": enc_v, "d": D_ENC, "ref": "ENCODER"})
    # power + mode LEDs flanking the encoder
    cuts.append({"kind": "circle", "u": enc_u - RING_OD/2 - 13, "v": enc_v, "d": D_LEDBZ, "ref": "PWR_LED"})
    cuts.append({"kind": "circle", "u": enc_u + RING_OD/2 + 13, "v": enc_v, "d": D_LEDBZ, "ref": "MODE_LED"})
    return cuts, engr

def rear_holes():
    """Rear-wall I/O: power in, button, fuse, USB x2, vents, earth stud.
    Local x=0..W (u), z=0..H_REAR. No audio aperture, no pedal slot."""
    z = 55.0
    cuts = [
        {"kind": "circle", "u": 60.0,  "v": z, "d": D_BARREL, "ref": "9V_DC"},
        {"kind": "circle", "u": 110.0, "v": z, "d": D_PWRBTN, "ref": "POWER"},
        {"kind": "circle", "u": 160.0, "v": z, "d": D_FUSE,   "ref": "FUSE"},
        {"kind": "rect", "u": 210.0, "v": z-7, "w": 14.0, "h": 14.0, "ref": "USB-A_1"},
        {"kind": "rect", "u": 245.0, "v": z-7, "w": 14.0, "h": 14.0, "ref": "USB-A_2"},
        {"kind": "circle", "u": 300.0, "v": 22.0, "d": D_GND, "ref": "EARTH_STUD"},
    ]
    cuts += _vent_array(u0=360.0, z0=25.0, cols=10, rows=6)   # rear exhaust vents
    return cuts

def _vent_array(u0, z0, cols, rows):
    """A block of louvre slots; returns rect features on the VENT layer."""
    sl, sw = VENT_SLOT
    out = []
    for r in range(rows):
        for c in range(cols):
            out.append({"kind": "rect", "u": u0 + c * (sl + 14.0), "v": z0 + r * VENT_PITCH,
                        "w": sl, "h": sw, "ref": "VENT", "layer": "VENT"})
    return out

def _vent_free_area(feats):
    sl, sw = VENT_SLOT
    return sum(f["w"] * f["h"] for f in feats if f.get("ref") == "VENT")

# ===========================================================================
# ASSERTION SUITE — the real acceptance gate (raises on bad geometry)
# ===========================================================================

def _bbox(f):
    """(umin, vmin, umax, vmax) of a faceplate feature in schedule coords."""
    if f["kind"] == "rect":
        return (f["u"], f["v"], f["u"] + f["w"], f["v"] + f["h"])
    r = (f["od"] if f["kind"] == "ring" else f["d"]) / 2.0
    return (f["u"] - r, f["v"] - r, f["u"] + r, f["v"] + r)

def _overlap(a, b, clr=2.0):
    return not (a[2] + clr <= b[0] or b[2] + clr <= a[0] or
                a[3] + clr <= b[1] or b[3] + clr <= a[1])

def _check():
    """Validate the geometry. Raises AssertionError with a clear message."""
    cuts, _ = faceplate_holes()
    rear = rear_holes()
    byref = {c["ref"]: c for c in cuts}

    # 1. width budget: the front row of 8 pedals must fit across FP_W
    row1 = sorted(u for _, u, v in PEDALS if v == PEDAL_ROW1_V)
    assert row1[0] - FSW_SLOT_W/2 >= 8 and row1[-1] + FSW_SLOT_W/2 <= FP_W - 8, (
        f"WIDTH_BUDGET: front row spans {row1[0]:.0f}..{row1[-1]:.0f}, "
        f"slot {FSW_SLOT_W:.0f} won't fit in {FP_W:.0f}")
    gaps = [b - a for a, b in zip(row1, row1[1:])]
    assert min(gaps) >= FSW_SLOT_W + 2.0, (
        f"WIDTH_BUDGET: min pedal gap {min(gaps):.0f} < slot {FSW_SLOT_W:.0f}+2")

    # 2. no two faceplate cutouts overlap (encoder bush is concentric in the ring)
    exempt = {frozenset(("RING", "ENCODER"))}
    boxes = [(c["ref"], _bbox(c)) for c in cuts]
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            (ra, a), (rb, b) = boxes[i], boxes[j]
            if frozenset((ra, rb)) in exempt:
                continue
            assert not _overlap(a, b), f"NO_OVERLAP: {ra} intersects {rb}"

    # everything must sit inside the usable faceplate (margin from welded edges)
    for ref, b in boxes:
        assert b[0] >= 8 and b[2] <= FP_W - 8 and b[1] >= 8 and b[3] <= FP_V - 8, \
            f"BOUNDS: {ref} outside the faceplate usable area"

    # 3. platform head-room for BOTH rows: foot-plate flush+proud at each depth
    for v in (PEDAL_ROW1_V, PEDAL_ROW2_V):
        ph = platform_h(v)
        assert ph > STANDOFF_H, f"PLATFORM_HEADROOM: platform {ph:.1f} <= standoff {STANDOFF_H} at v={v:.0f}"
        body_top = ph + ASP1_H
        assert abs(body_top - (lid_top_z(v) + FOOTPLATE_PROUD)) <= 0.5, \
            f"PLATFORM_HEADROOM: pedal top {body_top:.1f} not flush at v={v:.0f}"

    # 4. screen depth: each module clears the interior under the lid (read positions)
    for ref, dep in (("SCREEN_16IN", BIG_DEPTH), ("SCREEN_7IN", SMALL_DEPTH)):
        s = byref[ref]; v_mid = s["v"] + s["h"] / 2.0
        interior = lid_under_z(v_mid)
        assert dep <= interior, (
            f"SCREEN_DEPTH: {ref} needs {dep} mm, interior {interior:.1f} mm at v={v_mid:.0f}")

    # 4b. front-row pedals must clear the 16" module in v OR u (no in-box clash)
    s16 = byref["SCREEN_16IN"]
    pedal_v_max = PEDAL_ROW1_V + FSW_SLOT_D / 2.0
    for label, u, v in PEDALS:
        if v != PEDAL_ROW1_V:
            continue
        if pedal_v_max + 4.0 > s16["v"]:                       # overlaps in v
            assert u + FSW_SLOT_W/2 <= s16["u"] or u - FSW_SLOT_W/2 >= s16["u"] + s16["w"], \
                f"SCREEN_DEPTH: pedal {label} clashes with 16in screen"

    # 5. ventilation free area + standoff height
    area = _vent_free_area(rear) + _vent_free_area(_bottom_vents())
    assert area >= VENT_FREE_AREA_MIN, (
        f"VENT_FREE_AREA: {area:.0f} mm^2 < target {VENT_FREE_AREA_MIN:.0f}")
    assert STANDOFF_H >= 8.0, "VENT: under-board gap too small for airflow"

    # 6. screen bezel overlaps the aperture (mount from behind)
    assert BIG_W < BIG_BEZEL[0] and BIG_H < BIG_BEZEL[1], "SCREEN_RETENTION: 16in aperture >= bezel"
    assert SMALL_W < SMALL_BEZEL[0] and SMALL_H < SMALL_BEZEL[1], "SCREEN_RETENTION: 7in aperture >= bezel"

    # 7. PEM land width sufficient on the bottom flange
    assert FLANGE >= PEM_EDGE + 2.0, f"PEM: flange {FLANGE} < edge dist {PEM_EDGE}+2"
    return True

def _bottom_vents():
    return _vent_array(u0=W/2 - 120, z0=D/2 - 30, cols=6, rows=8)

# ===========================================================================
# DXF  (ezdxf)
# ===========================================================================

def _doc():
    import ezdxf
    doc = ezdxf.new("R2018", setup=True)
    doc.units = 4  # mm
    doc.layers.add("CUT", color=7)
    doc.layers.add("BEND", color=4, linetype="DASHED")
    doc.layers.add("ENGRAVE", color=3)
    doc.layers.add("VENT", color=7)
    doc.layers.add("WELD", color=6)
    doc.layers.add("NOTE", color=8)
    return doc

def _circle(msp, x, y, d, layer="CUT"):
    msp.add_circle((x, y), d / 2.0, dxfattribs={"layer": layer})

def _poly(msp, pts, layer="CUT", closed=True):
    msp.add_lwpolyline(pts, close=closed, dxfattribs={"layer": layer})

def _rrect(msp, x, y, w, h, r=R_FILLET, layer="CUT"):
    r = max(0.0, min(r, w / 2.0, h / 2.0))
    if r == 0.0:
        _poly(msp, [(x, y), (x+w, y), (x+w, y+h), (x, y+h)], layer); return
    b = math.tan(math.radians(45.0))
    pts = [(x+r, y, 0.0), (x+w-r, y, b), (x+w, y+r, 0.0), (x+w, y+h-r, b),
           (x+w-r, y+h, 0.0), (x+r, y+h, b), (x, y+h-r, 0.0), (x, y+r, b)]
    msp.add_lwpolyline(pts, format="xyb", close=True, dxfattribs={"layer": layer})

def _text(msp, x, y, h, s, layer="ENGRAVE"):
    msp.add_text(s, height=h, dxfattribs={"layer": layer}).set_placement((x, y))

def _emit(msp, feats, ox=0.0, oy=0.0):
    for f in feats:
        layer = f.get("layer", "CUT")
        x, y = f["u"] + ox, f["v"] + oy
        if f["kind"] == "circle":
            _circle(msp, x, y, f["d"], layer)
        elif f["kind"] == "ring":
            _circle(msp, x, y, f["od"], layer); _circle(msp, x, y, f["id"], layer)
        elif f["kind"] == "rect":
            _rrect(msp, x, y, f["w"], f["h"],
                   r=(0.0 if layer in ("ENGRAVE",) else R_FILLET), layer=layer)

# ---- parts -----------------------------------------------------------------

def dxf_faceplate(path):
    """Flat top plate (welded to front/rear/sides) + all cutouts. No flanges."""
    doc = _doc(); msp = doc.modelspace()
    _poly(msp, [(0, 0), (FP_W, 0), (FP_W, FP_V), (0, FP_V)], "CUT")
    cuts, engr = faceplate_holes()
    _emit(msp, cuts)
    for e in engr:
        _text(msp, e["u"], e["v"], e["h"], e["s"])
    _text(msp, 10, FP_V + 8, 8, "VAMP FACEPLATE  2.0mm 5052  x1  WELD all 4 edges to shell", "NOTE")
    doc.saveas(path)
    return {"blank": (FP_W, FP_V)}

def _wall(doc, length, height, label, io=None):
    """A wall panel: flat web (length x height) + a bottom return-flange (folded
    inward for the bottom plate's PEM nuts). io = optional feature list."""
    msp = doc.modelspace()
    _poly(msp, [(0, -FL), (length, -FL), (length, height), (0, height)], "CUT")
    _poly(msp, [(0, 0), (length, 0)], "BEND", closed=False)            # bottom fold
    # PEM clinch holes along the bottom flange
    n = max(2, int(length // 120))
    for k in range(n + 1):
        x = 20 + k * (length - 40) / n
        _circle(msp, x, -FL/2.0, PEM_M4, "WELD" if False else "CUT")
    if io:
        _emit(msp, io)
    _text(msp, 10, height + 6, 8, label, "NOTE")

def dxf_front(path):
    doc = _doc(); _wall(doc, W - 2*T, H_FRONT, "VAMP FRONT  2.0mm  x1  bottom flange fold")
    doc.saveas(path); return {}

def dxf_rear(path):
    doc = _doc(); _wall(doc, W - 2*T, H_REAR, "VAMP REAR  2.0mm  x1  I/O + vents + earth", io=rear_holes())
    doc.saveas(path); return {}

def dxf_side(path, hand):
    """Trapezoid side web + bottom return-flange (fold)."""
    doc = _doc(); msp = doc.modelspace()
    _poly(msp, [(0, -FL), (D, -FL), (D, H_REAR), (0, H_FRONT)], "CUT")
    _poly(msp, [(0, 0), (D, 0)], "BEND", closed=False)
    _poly(msp, [(0, H_FRONT), (D, H_REAR)], "WELD", closed=False)  # weld edge to faceplate
    for x in (40.0, D/2.0, D-40.0):
        _circle(msp, x, -FL/2.0, PEM_M4)
    _text(msp, 20, 20, 8, f"VAMP SIDE_{hand}  2.0mm  x1  top edge WELD to faceplate", "NOTE")
    doc.saveas(path); return {}

def dxf_bottom(path):
    """Removable vented bottom plate: vents + Pi standoff holes + perimeter M4
    clearance (bolts up into the shell's bottom-flange PEM nuts) + feet + ground."""
    doc = _doc(); msp = doc.modelspace()
    bw, bd = W - 2*T, D - 2*T
    _poly(msp, [(0, 0), (bw, 0), (bw, bd), (0, bd)], "CUT")
    _emit(msp, _bottom_vents_local(bw, bd))
    # Pi standoff pattern (M3 clearance holes; standoffs lift the Pi STANDOFF_H)
    sx, sy = STANDOFF_PITCH
    cx, cy = bw*0.30, bd*0.5
    for dx in (-sx/2, sx/2):
        for dy in (-sy/2, sy/2):
            _circle(msp, cx+dx, cy+dy, D_M3)
    # perimeter M4 clearance to the shell flanges
    for x in (25, bw/2, bw-25):
        _circle(msp, x, 12, D_M4); _circle(msp, x, bd-12, D_M4)
    for y in (bd*0.33, bd*0.66):
        _circle(msp, 12, y, D_M4); _circle(msp, bw-12, y, D_M4)
    # feet + masked ground contact pad note
    for x in (35, bw-35):
        for y in (35, bd-35):
            _circle(msp, x, y, D_FOOT)
    _text(msp, 25, bd-10, 5, "MASK powder-coat at perimeter M4 pads (chassis bond)", "WELD")
    _text(msp, 10, bd+6, 8, "VAMP BOTTOM (removable)  2.0mm  x1  vented + Pi standoffs", "NOTE")
    doc.saveas(path); return {}

def _bottom_vents_local(bw, bd):
    sl, sw = VENT_SLOT
    cols, rows = 6, 8
    u0, v0 = bw/2 - (cols*(sl+14))/2, bd/2 - (rows*VENT_PITCH)/2
    out = []
    for r in range(rows):
        for c in range(cols):
            out.append({"kind": "rect", "u": u0 + c*(sl+14), "v": v0 + r*VENT_PITCH,
                        "w": sl, "h": sw, "ref": "VENT", "layer": "VENT"})
    return out

def dxf_platform(path):
    """Inner pedal platform: shelf the ASP-1 stands on + two downturned legs with
    weld tabs (spot-welded to the front wall + an internal cross-rib). qty 10."""
    doc = _doc(); msp = doc.modelspace()
    sw = ASP1_W + 2*PLATFORM_MARGIN
    sd = ASP1_D + 2*PLATFORM_MARGIN
    leg = PLATFORM_H - T
    # developed: [leg][shelf][leg] along the depth, legs fold down
    _poly(msp, [(0, 0), (sw, 0), (sw, leg), (sw, leg+sd), (sw, leg+sd+leg),
                (0, leg+sd+leg), (0, leg+sd), (0, leg), (0, 0)], "CUT")
    _poly(msp, [(0, leg), (sw, leg)], "BEND", closed=False)
    _poly(msp, [(0, leg+sd), (sw, leg+sd)], "BEND", closed=False)
    # weld tabs along the leg feet
    _poly(msp, [(0, 0), (sw, 0)], "WELD", closed=False)
    _poly(msp, [(0, leg+sd+leg), (sw, leg+sd+leg)], "WELD", closed=False)
    _text(msp, 5, leg+sd+leg+6, 6,
          f"VAMP PLATFORM  2.0mm  x10  PROVISIONAL (set to ASP-1)  spot-weld feet", "NOTE")
    doc.saveas(path); return {}

def dxf_screen_bracket(path):
    """Rear clamp bracket that retains a bezel monitor from behind (qty per
    screen). Simple L: a face that PEMs to the shell + a return that the monitor
    clamps against. Two sizes noted."""
    doc = _doc(); msp = doc.modelspace()
    bl, bh = 60.0, 30.0
    _poly(msp, [(0, -FL), (bl, -FL), (bl, bh), (0, bh)], "CUT")
    _poly(msp, [(0, 0), (bl, 0)], "BEND", closed=False)
    for x in (15, bl-15):
        _circle(msp, x, -FL/2.0, PEM_M4)
        _circle(msp, x, bh/2.0, D_M4)
    _text(msp, 5, bh+6, 6, "VAMP SCREEN BRACKET  2.0mm  x4 (16in) + x4 (7in)", "NOTE")
    doc.saveas(path); return {}

# ===========================================================================
# STEP  (cadquery)
# ===========================================================================

def _cut(cq, plate, feats, mapxy):
    for c in feats:
        if c.get("layer", "CUT") not in ("CUT", "VENT"):
            continue
        if c["kind"] in ("circle", "ring"):
            d = c["d"] if c["kind"] == "circle" else c["od"]
            x, y = mapxy(c["u"], c["v"])
            cutter = cq.Workplane("XY").center(x, y).circle(d/2).extrude(3*T).translate((0,0,-T))
        elif c["kind"] == "rect":
            x, y = mapxy(c["u"] + c["w"]/2, c["v"] + c["h"]/2)
            cutter = cq.Workplane("XY").center(x, y).rect(c.get("_rx", c["w"]), c.get("_ry", c["h"])).extrude(3*T).translate((0,0,-T))
        else:
            continue
        plate = plate.cut(cutter)
    return plate

def _faceplate_flat(cq):
    fp = cq.Workplane("XY").box(FP_V, FP_W, T, centered=False)   # X=v, Y=u
    cuts, _ = faceplate_holes()
    for c in cuts:
        if c["kind"] == "rect":
            c["_rx"], c["_ry"] = c["h"], c["w"]
    return _cut(cq, fp, cuts, lambda u, v: (v, u))

def _rear_flat(cq):
    wall = cq.Workplane("XY").box(W-2*T, H_REAR, T, centered=False)  # X=u, Y=z
    feats = rear_holes()
    for c in feats:
        if c["kind"] == "rect":
            c["_rx"], c["_ry"] = c["w"], c["h"]
    return _cut(cq, wall, feats, lambda u, v: (u, v))

def _platform_solid(cq, ph):
    sw = ASP1_W + 2*PLATFORM_MARGIN
    sd = ASP1_D + 2*PLATFORM_MARGIN
    shelf = cq.Workplane("XY").box(sd, sw, T, centered=(True, True, False)).translate((0,0,ph))
    legf = cq.Workplane("XY").box(T, sw, ph, centered=(True, True, False)).translate((-sd/2+T/2,0,0))
    legr = cq.Workplane("XY").box(T, sw, ph, centered=(True, True, False)).translate((sd/2-T/2,0,0))
    return shelf.union(legf).union(legr)

def build_step(write_parts=True):
    import cadquery as cq
    os.makedirs(OUT, exist_ok=True)
    asm = cq.Assembly(name="VAMP")
    # global: X=depth (0 front->D rear), Y=width (0..W), Z=up
    bottom = cq.Workplane("XY").box(D-2*T, W-2*T, T, centered=False).translate((T, T, 0))
    front  = cq.Workplane("XY").box(T, W-2*T, H_FRONT, centered=False).translate((0, T, 0))
    rear   = _rear_flat(cq)
    side   = cq.Workplane("XZ").polyline([(0,0),(D,0),(D,H_REAR),(0,H_FRONT)]).close().extrude(-T)
    fp     = _faceplate_flat(cq).mirror("XZ", (0, FP_W/2.0, 0))   # 7" -> player's LEFT

    asm.add(bottom, name="bottom", loc=cq.Location(cq.Vector(0, 0, 0)))
    asm.add(front,  name="front",  loc=cq.Location(cq.Vector(0, 0, 0)))
    rear_loc = (cq.Location(cq.Vector(D - T, T, 0))
                * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), 90)
                * cq.Location(cq.Vector(0,0,0), cq.Vector(0,0,1), 90))
    asm.add(rear, name="rear", loc=rear_loc)
    asm.add(side, name="side_L", loc=cq.Location(cq.Vector(0, 0, 0)))
    asm.add(side, name="side_R", loc=cq.Location(cq.Vector(0, W - T, 0)))
    fp_loc = (cq.Location(cq.Vector(0, T, H_FRONT))
              * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), -SLOPE_ANGLE))
    asm.add(fp, name="faceplate", loc=fp_loc)
    # 10 inner platforms under the pedal slots (X = pedal v, Y = pedal u);
    # mid-row (CLEAR/BANK) platforms are taller because the lid is higher there.
    for i, (label, u, v) in enumerate(PEDALS):
        plat = _platform_solid(cq, platform_h(v))
        asm.add(plat, name=f"platform_{i}", loc=cq.Location(cq.Vector(v, u + T, 0)))

    asm.save(os.path.join(OUT, "vamp_assembly.step"))
    if write_parts:
        exp = cq.exporters.export
        exp(bottom, os.path.join(OUT, "vamp_bottom.step"))
        exp(rear,   os.path.join(OUT, "vamp_rear.step"))
        exp(front,  os.path.join(OUT, "vamp_front.step"))
        exp(side,   os.path.join(OUT, "vamp_side.step"))
        exp(fp,     os.path.join(OUT, "vamp_faceplate.step"))
        exp(plat,   os.path.join(OUT, "vamp_platform.step"))
    return os.path.join(OUT, "vamp_assembly.step")

# ===========================================================================
# PDF drawing sheets
# ===========================================================================

def dxf_to_pdf(dxf_path, pdf_path, title="", material="2.0 mm 5052-H32 Al", qty=1):
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import ezdxf
    from ezdxf.addons.drawing import RenderContext, Frontend
    from ezdxf.addons.drawing.matplotlib import MatplotlibBackend
    from ezdxf.bbox import extents
    doc = ezdxf.readfile(dxf_path)
    doc.layers.get("CUT").rgb = (0, 0, 0)   # ACI-7 -> black on white
    msp = doc.modelspace()
    fig = plt.figure(figsize=(16, 10))
    ax = fig.add_axes([0.04, 0.10, 0.92, 0.86]); ax.set_axis_off()
    Frontend(RenderContext(doc), MatplotlibBackend(ax)).draw_layout(msp, finalize=True)
    ax.set_aspect("equal")
    bb = extents(e for e in msp if e.dxf.layer not in ("NOTE", "ENGRAVE", "ACRYLIC"))
    if bb.has_data:
        x0, y0, _ = bb.extmin; x1, y1, _ = bb.extmax
        ax.annotate(f"{x1-x0:.1f}", ((x0+x1)/2, y0), ha="center", va="top", fontsize=11, color="#0a4")
        ax.annotate(f"{y1-y0:.1f}", (x0, (y0+y1)/2), ha="right", va="center", rotation=90, fontsize=11, color="#0a4")
    fig.text(0.04, 0.045, "VAMP loopstation enclosure  ·  loopy", fontsize=12, weight="bold")
    fig.text(0.04, 0.022,
             f"{title}   |   {material}   |   qty {qty}   |   units mm   |   "
             f"CUT(thru) · BEND(score) · WELD · VENT · ENGRAVE   |   bend R {RI:.1f}",
             fontsize=9, color="#333")
    fig.savefig(pdf_path, dpi=150); plt.close(fig)

# ===========================================================================
# REPORT
# ===========================================================================

def report():
    cuts, _ = faceplate_holes()
    L = []; P = L.append
    P("="*68)
    P("VAMP sheet-metal enclosure — manufacturing package")
    P("="*68)
    P(f"Envelope        : {W:.0f} W x {D:.0f} D x {H_REAR:.0f} H mm (front lip {H_FRONT:.0f})")
    P(f"Top slope       : {SLOPE_ANGLE:.2f}deg, sloped length {L_SLOPE:.1f} mm")
    P(f"Material        : {T:.1f} mm 5052-H32 Al, bend R {RI:.1f}, K={KF}, BA90 {BA90:.2f}")
    P(f"Construction    : WELDED shell + removable bottom plate (service)")
    P("-"*68)
    n1 = sum(1 for _, _, v in PEDALS if v == PEDAL_ROW1_V)
    P(f"Foot pedals     : {len(PEDALS)}x WHOLE Artesia ASP-1 ({ASP1_W:.0f}x{ASP1_D:.0f}x{ASP1_H:.0f}mm)")
    P(f"  layout        : {n1} front row + {len(PEDALS)-n1} centre (CLEAR/BANK), LEDs aligned above")
    P(f"  slot          : {FSW_SLOT_W:.0f}(u) x {FSW_SLOT_D:.0f}(v) mm  [PROVISIONAL]")
    P(f"  platform H    : front {platform_h(PEDAL_ROW1_V):.1f} / mid {platform_h(PEDAL_ROW2_V):.1f} mm "
      f"(foot-plate flush +{FOOTPLATE_PROUD:.0f})  [PROVISIONAL]")
    P(f"Screens         : 7in {SMALL_W:.0f}x{SMALL_H:.0f} (left) | 16in {BIG_W:.0f}x{BIG_H:.0f} (right), tops aligned, from behind")
    P(f"Rear I/O        : 9V barrel + power btn + fuse + USB-A x2 + vents + earth stud")
    P(f"Ventilation     : free area {_vent_free_area(rear_holes())+_vent_free_area(_bottom_vents()):.0f} mm^2 (>= {VENT_FREE_AREA_MIN:.0f}), standoff {STANDOFF_H:.0f}mm")
    P("-"*68)
    P(f"Faceplate cutouts : {len(cuts)}  |  rear-wall cutouts : {len(rear_holes())}")
    area = (W*D + W*L_SLOPE + W*H_REAR + W*H_FRONT) + 2*(D*(H_FRONT+H_REAR)/2)
    for mat, rho in (("5052 Al", 2.70), ("mild steel", 7.85)):
        P(f"Bare weight     : {area*T*rho/1e6:4.1f} kg  ({mat}, {T:.1f} mm, {area/1e6:.2f} m2)")
    P("="*68)
    return "\n".join(L)

# ===========================================================================
# MAIN
# ===========================================================================

DXF_PARTS = [
    ("vamp_faceplate",       dxf_faceplate),
    ("vamp_front",           dxf_front),
    ("vamp_rear",            dxf_rear),
    ("vamp_side_L",          lambda p: dxf_side(p, "L")),
    ("vamp_side_R",          lambda p: dxf_side(p, "R")),
    ("vamp_bottom",          dxf_bottom),
    ("vamp_platform",        dxf_platform),
    ("vamp_screen_bracket",  dxf_screen_bracket),
]
NO_PDF = {"vamp_platform"}   # minimal parts: DXF only

def main(argv):
    print(report())
    print("\nGeometry assertions ...", end=" ")
    _check()
    print("ALL PASS")
    if "--report" in argv:
        return
    os.makedirs(OUT, exist_ok=True)
    print("\nDXF flat patterns:")
    for name, fn in DXF_PARTS:
        dxf = os.path.join(OUT, name + ".dxf"); fn(dxf)
        print("  out/" + name + ".dxf")
        if "--no-pdf" not in argv and name not in NO_PDF:
            try:
                dxf_to_pdf(dxf, os.path.join(OUT, name + ".pdf"),
                           title=name.replace("vamp_", "").replace("_", " ").upper())
                print("  out/" + name + ".pdf")
            except Exception as e:  # pragma: no cover
                print(f"    (pdf skipped: {e})")
    if "--no-step" not in argv:
        try:
            p = build_step()
            print("\n3D STEP:\n  " + os.path.relpath(p, HERE) + " (+ per-part .step)")
        except Exception as e:  # pragma: no cover
            print(f"\n(STEP skipped: {e})")

if __name__ == "__main__":
    main(set(sys.argv[1:]))
