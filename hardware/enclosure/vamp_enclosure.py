"""VAMP — parametric sheet-metal enclosure for the loopy Pi loopstation.

Generates a **manufacturing package** for a wedge-shaped floor console modelled on
the "Chewie II" / Sonnit reference (850 x 465 x 100 mm, top sloping toward the
player), housing this repo's standalone build: a Raspberry Pi 4/5 running loopy,
the loopy_pi_main board, ten foot pedals, the EC11 encoder + diffused LED ring,
SMD LED-strip status indicators (WS2812B segments behind diffuser slots) and a
7" + 16" touchscreen pair. Branded **VAMP**.

Construction (see ../loopy_vamp_enclosure_design.md and
../../docs/plan/2026-06-27-feat-vamp-enclosure-rework-plan.md):

  WELDED LOWER BODY (one rigid tray)        REMOVABLE TOP LID
  - front wall (12) + top flange (ledge)    - faceplate pan (sloped top, all cutouts)
  - rear wall (100) + I/O + vents + flange    + down-turned front/side/rear skirts
  - 2x side panel + top flange (ledge)        (lid screws on the SKIRTS, not the top)
  - bottom plate (welded, vented, Pi/board) - 2x screen-retention bracket
  - 10x inner pedal platform (welded)

Foot controls = ten WHOLE Artesia ASP-1 pedals (100x75x25 mm) standing on the
welded inner platforms, foot-plates protruding through ~75x100 mm slots. No
top-face fasteners; pedal wiring stays internal. Service = back out the side +
front-lip screws and lift the lid (screens + ring PCB + LEDs go with it; pedals
stay on their platforms).

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
FACE_RUN = 397.0     # depth of the TOP PLATE control area (front edge -> the peak),
                     # sized so the screen block sits FRONT_GAP behind the front row
                     # with an EDGE rear margin
H_REAR   = 100.0     # peak height (rear edge of the Top plate = tallest point)
H_FRONT  = 12.0      # front lip height (low end) -- nearly at the floor. The lid front lip
                     # screws horizontally into this wall. DFM CAVEAT: at 12mm the flat wall
                     # is only ~9mm, so the M4 lands ~2.5mm from the fold -- laser the hole and
                     # tap/finish AFTER bending. A fully-clear front screw needs a taller front
                     # (~17mm); an inward screw-ledge is blocked by the front-pedal row (~8mm).

# Rear of the body steps down via an ANGLED TRANSITION SURFACE (a beveled shoulder)
# instead of the Top plate folding straight to the Rear panel. The transition is a
# flange folded forward+up from the (shortened) Rear panel's top, steeper than the
# Top plate; the Top plate's rear edge laps onto it and screws down -- so it is a
# NATURAL SUPPORT for the Top plate.
TRANS_RUN  = 22.0    # transition horizontal run (depth added behind the control area) --
                     # short, so the transition shoulder is only as deep as the lid's
                     # rear lap covers (keeps the ~25deg rake, pulls the rear panel
                     # forward, reduces the bottom-plate depth)
TRANS_DROP = 10.0    # transition vertical drop (peak -> rear-panel top)

T        = 2.0       # sheet thickness (2.0 mm 5052-H32 aluminium)
RI       = 2.0       # inside bend radius (= T, safe for 5052)
KF       = 0.33      # K-factor for bend-allowance development
FLANGE   = 18.0      # return-flange depth (lid side wings + wall top flange)
# Weld-free corner join: internal L-brackets riveted through both walls. These MUST match
# between the base rivet holes, the bracket parts, and the viewer render.
CORNER_RO = 8.0      # rivet offset ALONG each wall from the corner (hug the corner, clear the I/O panel)
CORNER_LEG = 12.0    # bracket leg width (along the wall)
# REAR-corner rivets are STAGGERED between the two legs so a wall-leg rivet and a side-leg
# rivet never sit at the same height (their tips would meet at the corner). Heights are from
# the bottom-plate top.
CORNER_ZR_WALL = (8.0, 40.0, 72.0)    # rear-wall leg rivets (3)
CORNER_ZR_SIDE = (24.0, 56.0)         # side-wall leg rivets (2), interleaved with the wall leg
CORNER_HT      = 80.0                  # rear bracket height (covers the ~90 mm rear wall)
LID_FRONT_FL = 9.0   # front-lip flange flat (down-turned lip; rests on the front wall, no screw)
# LID_REAR_LAP (rear-lap length) is DERIVED by the rear-seam solver below
LID_SIDE_LIP = 16.0  # inward lip at the bottom of each lid side wall (screws to the base from below)
# Lid -> body fixing scheme:
#   FRONT  : the Top plate's front lip screws horizontally into the Front panel.
#   REAR   : the Top plate's rear edge laps onto the angled TRANSITION SURFACE and
#            screws straight down into PEM nuts there (no fixing on the Rear panel).
#   SIDES  : the Top plate has down-turned WINGS that tuck INSIDE the Side panels
#            for repeatable lateral alignment (locating only, no screws).

# --- foot pedals: whole Artesia ASP-1 (100 x 75 x 25 mm), PROVISIONAL ---------
# Measure a real ASP-1 before cutting metal. Mounted 75 across the panel (u),
# 100 front-to-back (v), 25 body height into -Z.
ASP1_W, ASP1_D, ASP1_H = 75.0, 100.0, 25.0    # pedal footprint W(u) x D(v) x H(z)
FSW_SLOT_W = ASP1_W + 3.0     # slot clearance around the foot-plate (u)
FSW_SLOT_D = ASP1_D + 3.0     # slot clearance (v)
FSW_V      = 80.0             # front-row centre line (v)
FSW_PITCH  = 80.0             # centre-to-centre across the row
FOOTPLATE_PROUD = 10.0        # foot-plate stands this far above the sloped top (so the
                              # pedals sit at a good height even with the low front lip)
PLATFORM_MARGIN = 2.0         # platform shelf overhang past the pedal footprint (stay within the slot)
PLATFORM_LEG_W  = 14.0        # weld-tab / leg width
PLATFORM_FOOT   = 18.0        # IN-turned foot-flange width (M3 screw >=7mm from the flange bend)

# --- screens (capacitive touch, mounted from BEHIND; aperture < bezel) --------
BIG_BEZEL  = (360.0, 224.0)   # 15.6" no-shell capacitive panel outline (glass edge-to-edge)
BIG_W, BIG_H     = 344.0, 194.0   # 15.6" active area (344.16 x 193.59), 1920x1080 16:9 -> aperture
BIG_DEPTH  = 8.0              # thin panel (3-6 mm); HDMI/USB driver board mounts flat inside
SMALL_BEZEL = (165.0, 100.0)  # 7" module outline (APROTII: ears 164x99)
SMALL_W, SMALL_H = 156.0, 88.0    # 7" aperture (APROTII active 155x86)
SMALL_DEPTH = 12.0           # 7" panel body 9 mm + connectors (APROTII sheet)

# --- LEDs / encoder -----------------------------------------------------------
# Status indicators = SMD LEDs (WS2812B), NOT through-hole: ONE single-LED
# board per indicator pedal (hardware/led_strip/, 16 x 8 mm puck) stuck to the
# faceplate UNDERSIDE with VHB tape; a small milky PMMA pill diffuser sets into
# each slot and glows through. Boards daisy-chain pedal-to-pedal with 3 wires
# (5V/data/GND) on the castellated end pads.
LED_SLOT_H = 6.0          # diffuser-slot height (v); corner r = H/2 -> full round ends
LED_SLOT_W = 60.0         # pill window per indicator pedal (one 5050 diffused behind it)
LED_INS_CLR   = 0.2       # diffuser-insert lateral clearance in the slot (total)
LED_INS_PROUD = 0.4       # lens stands this far above the outer skin
LED_INS_FLANGE = 3.0      # shoulder overhang past the slot, all around (seats on the
                          # faceplate UNDERSIDE -- the insert pushes in from INSIDE)
LED_INS_FL_T  = 1.5       # shoulder thickness
LED_INS_POCKET = (6.0, 6.0, 0.8)  # LED nest recess in the shoulder's back face
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
D_HDMI    = (16.0, 8.0)  # HDMI Type-A panel cutout (w,h)
D_USB     = (14.0, 7.0)  # USB-A panel cutout (w,h)
D_PI_IO   = (54.0, 17.0) # Raspberry Pi rear-edge port stack (2x USB-A + RJ45) cutout (w,h)
# Rear connector WINDOW: a fixed opening in the welded rear wall, closed by a SWAPPABLE
# I/O sub-panel that carries the version-specific connectors (Pi vs no-Pi).
REAR_WIN_W = 290.0; REAR_WIN_H = 46.0    # window opening (w,h)
REAR_WIN_U = 175.0                        # window centre u; REAR_WIN_Z set below (= wall mid-height)

# --- ventilation / mounting ---------------------------------------------------
VENT_SLOT   = (40.0, 4.0)     # one louvre slot (l x w)
VENT_PITCH  = 8.0             # slot row pitch (web = pitch - slot = 4mm = 2T)
VENT_FREE_AREA_MIN = 4000.0   # mm^2 minimum open area (bottom + rear), ~40 cm^2
STANDOFF_H  = 15.0            # under-board gap: the THT leads + buck-module header pins
                              # hang ~4.5mm below the PCB, so 10mm left ~5mm of real
                              # airflow; 15mm (standard M3 brass) restores the margin
PI_STACK_MID = 9.7            # USB/RJ45 stack centreline above the Pi PCB BOTTOM
                              # (1.6 PCB + ~8.1 to the middle of the 16mm-tall stack);
                              # PI_RISER_H is derived from it below REAR_WIN_Z
PI_HOLES    = (58.0, 49.0)    # Raspberry Pi 4/5 mounting-hole rectangle (M2.5)
# Main board = the manufactured V1 THT Pro Micro board (the loopy_pedal_main THT design,
# git 794eb48; the later SMD 328P+16U2 redesign is discarded). Measured from its KiCad:
# 4x M3 over an 85 x 87 mm rectangle, centred on a 94 x 96 mm outline. Same board (alone)
# in the Base build; in the Pi build a Raspberry Pi rides alongside via the GPIO header.
BOARD_HOLES = (85.0, 87.0)    # M3 mount rectangle (measured, THT Pro Micro V1)
BOARD_SIZE  = (94.0, 96.0)    # board outline (for the 3D render)
D_FOOT    = 8.0      # rubber-foot fixing

# --- fasteners ----------------------------------------------------------------
D_M3      = 3.2      # M3 clearance (Pi/board standoffs)
D_M2      = 2.4      # M2 clearance (external buck standoffs)
D_M4      = 4.3      # M4 clearance (bottom plate -> shell)
PEM_M4    = 6.3      # PEM M4 clinch hole (DISTINCT from M4 clearance)
PEM_EDGE  = 8.0      # min PEM centre-to-edge distance
R_FILLET  = 3.0      # inside corner radius on rectangular cutouts

# ===========================================================================
# DERIVED GEOMETRY
# ===========================================================================

D           = FACE_RUN + TRANS_RUN + 2*T  # overall depth: +2T so the bottom plate
                                          # BD (= D-2T) = FACE_RUN+TRANS_RUN, i.e. the side
                                          # wall's rear edge spans TRANS_RUN at TRANS_ANGLE,
                                          # matching the transition flap exactly
# Profile A: the Top plate rises to the PEAK at its rear edge (H_REAR), then the angled
# transition DROPS from the peak down to the shorter Rear panel at the very back.
REAR_WALL_H = H_REAR - TRANS_DROP     # Rear panel height (reduced; below the peak)
REAR_WIN_Z  = REAR_WALL_H / 2.0       # I/O window centred vertically on the rear wall
# Pi build: risers lift the Pi so its rear port stack CENTRES in the I/O window
# (window centre = REAR_WIN_Z up the wall ~= the same height above the bottom
# plate). The old hardcoded 33.0 left the stack ~2.3mm low - the USB shells'
# bottom edge hid behind the sub-panel cutout edge.
PI_RISER_H  = REAR_WIN_Z - PI_STACK_MID
SLOPE_DROP  = H_REAR - H_FRONT
L_SLOPE     = math.hypot(FACE_RUN, SLOPE_DROP)            # Top-plate sloped length
SLOPE_ANGLE = math.degrees(math.atan2(SLOPE_DROP, FACE_RUN))
TRANS_LEN   = math.hypot(TRANS_RUN, TRANS_DROP)          # transition facet length
TRANS_ANGLE = math.degrees(math.atan2(TRANS_DROP, TRANS_RUN))   # transition rake (from horizontal)

def bend_allowance(angle_deg, t=T, ri=RI, k=KF):
    return math.radians(angle_deg) * (ri + k * t)

BA90 = bend_allowance(90.0)

def dev_deduct(angle_deg):
    """Per-flap development deduction for a fold of the given rotation angle
    (exact K-factor development, bend line on the mold line, centre-line
    convention): flap flat = target outer length - dev_deduct(angle)."""
    a = math.radians(angle_deg)
    return (RI + T) * math.tan(a / 2.0) - bend_allowance(angle_deg) / 2.0

DEV90 = dev_deduct(90.0)              # = 1.911 for T2/RI2/K0.33 (issue #237: the old
                                      # T + K*T = 2.66 over-deducted every 90 deg bend
                                      # ~0.75mm, leaving all walls short of nominal)
# The lap must STOP SHORT of the wall->flange bend knuckle: the flange's outer
# surface starts curving (RI+T)*tan(fold/2) = 2.58 before the outside mold
# corner, so the lap tip stops there plus a margin -- as LONG as possible while
# still lying flat on the flange.
KNUCKLE_CLEAR = 3.5
FP_W = W - 2.0 * T                    # control-area width (schedule coordinate frame)
LID_W = W - 0.2                       # lid blank full outer width: covers the wall tops,
                                      # flush with the side skins (issue #237)
LID_OX = (LID_W - FP_W) / 2.0         # schedule content offset inside the wider blank
FP_V = L_SLOPE                        # faceplate length up the slope (control area)

# --- rear-seam development solver (issue #237) --------------------------------
# Side view of the FOLDED part: Z = depth from the front wall OUTER face,
# Y = height above the bottom plate OUTER face. Every position is derived from
# the flats' own developed geometry (bend lines + dev_deduct), NOT from the
# idealized design polygon -- development shifts the real planes a couple of mm
# from the polygon, and the seam must close on the planes the flats actually
# produce.
_ra, _rth = math.radians(SLOPE_ANGLE), math.radians(TRANS_ANGLE)
DD_LIP = dev_deduct(90.0 - SLOPE_ANGLE)         # lid front-lip fold (77.5 deg)
DD_LAP = dev_deduct(SLOPE_ANGLE + TRANS_ANGLE)  # lid rear-lap fold (36.9 deg)
DD_TR  = dev_deduct(90.0 - TRANS_ANGLE)         # wall -> flange fold (65.6 deg)
_bd  = D - 2.0 * T                              # bottom plate flat depth (= BD)
# lid front mold corner (lip outer face x lid outer skin), lip hugging the wall:
_cfy = H_FRONT - T * math.tan(_ra) + T / math.cos(_ra)
_cfz = -DEV90 - T
_mtop   = FP_V + DD_LIP + DD_LAP                # lid top-plate mold length
RIDGE_Z = _cfz + _mtop * math.cos(_ra)          # lid rear mold corner (the ridge)
RIDGE_Y = _cfy + _mtop * math.sin(_ra)
_zw  = _bd + DEV90                              # rear wall OUTER plane depth
_y90 = RIDGE_Y - (_zw - RIDGE_Z) * math.tan(_rth)   # lap outer  x  wall outer
YC_TRANS = _y90 - T / math.cos(_rth)            # transition OUTSIDE mold corner: the
                                                # flange outer sits ONE SHEET below
                                                # the lap outer so the lap rests ON it
HR_FLAT = YC_TRANS - DEV90 - DD_TR              # rear wall web, developed flat
RIDGE_CLEAR = 2.0                               # flange tip stops this short of the
                                                # ridge mold corner (lap-bend zone)
# along-facet axis d: from the ridge mold corner DOWN the lap/flange facet.
# A point at flat distance f beyond a bend line lands at facet station f + DD
# from that bend's mold corner (the straight flap starts sb past the corner but
# only BA/2 past the line) -- so a target station d needs flat = d - DD.
D_WALL    = (_zw - RIDGE_Z) * math.cos(_rth) + (RIDGE_Y - YC_TRANS) * math.sin(_rth)
HT_FLAT   = (D_WALL - RIDGE_CLEAR) - DD_TR      # transition flange, developed flat:
                                                # as LONG as possible (to the ridge
                                                # clearance, NOT just TRANS_LEN --
                                                # development stretches the facet)
D_FL_TIP  = D_WALL - (HT_FLAT + DD_TR)          # flange tip (= RIDGE_CLEAR)
D_LAP_TIP = D_WALL - KNUCKLE_CLEAR              # lap tip: clear of the wall knuckle
# screw row: centred on the lap/flange overlap, pushed down-facet if needed so
# the PEM keeps its edge distance from the flange tip
D_SEAM_SCREW = max((D_FL_TIP + D_LAP_TIP) / 2.0, D_FL_TIP + PEM_EDGE)
LID_REAR_LAP = D_LAP_TIP - DD_LAP               # lap developed flat length
LRL = LID_REAR_LAP
SEAM_M4_V  = LID_FRONT_FL + FP_V + (D_SEAM_SCREW - DD_LAP)     # lap M4 row (lid flat v)
SEAM_PEM_V = HR_FLAT + (D_WALL - D_SEAM_SCREW) - DD_TR         # flange PEM row (base
                                                               # flat, from the rear
                                                               # wall bend line)
# hard DFM guards: a parameter tweak must not silently collapse the lap/flange
# overlap or push the screw row off the lap (holes in air pass no other check)
assert HR_FLAT > 0 and LID_REAR_LAP > 0, "seam solver: degenerate rear seam"
assert D_FL_TIP + PEM_EDGE <= D_SEAM_SCREW <= D_LAP_TIP - (D_M4 / 2.0 + 2.0), (
    f"seam screw row d={D_SEAM_SCREW:.2f} outside the lap/flange overlap "
    f"[{D_FL_TIP:.2f}, {D_LAP_TIP:.2f}] with edge margins")
assert HR_FLAT > max(CORNER_ZR_WALL) + T + 2.0, (
    "rear web too short: corner-bracket rivet holes cross the transition fold")

def lid_top_z(v):
    """Z of the Top-plate surface at control-area depth v (0..FACE_RUN)."""
    return H_FRONT + SLOPE_DROP * (min(v, FACE_RUN) / FACE_RUN)

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
EDGE         = 30.0      # uniform edge margin (sides / rear)
FRONT_PEDAL_MARGIN = 10.0 # front-row pedals sit this close to the front edge
LED_GAP      = 12.0      # status-LED offset behind a pedal (toward rear)
SILK_H       = 25.0      # silkscreen cap height -- SAME for every label (a too-wide word
SILK_CW      = 0.66      # gets squished horizontally). bold char advance / cap height.
FRONT_GAP    = 65.0      # gap between the front-row rear edge and the screen block
PEDAL_ROW1_V = FRONT_PEDAL_MARGIN + FSW_SLOT_D / 2.0   # front row pulled to the edge
# 7" screen, LED ring and encoder share ONE vertical centre-line (COL_U, defined
# with the pedal layout below): the gap between pedals 1 and 2.
# The screen block sits FRONT_GAP behind the front row; its TOP edge is the rearmost
# control. D is chosen so FP_V - SCREEN_TOP_V (rear margin) also equals EDGE.
SCREEN_TOP_V = PEDAL_ROW1_V + FSW_SLOT_D / 2.0 + FRONT_GAP + BIG_H
# CLEAR/BANK sit so their BOTTOM (front) edge aligns with the 16" screen's bottom.
PEDAL_ROW2_V = (SCREEN_TOP_V - BIG_H) + FSW_SLOT_D / 2.0

# Front row of 8, EVENLY spaced across the faceplate (no 4+4 grouping).
_ROW1 = ["REC/PLAY", "STOP", "UNDO", "MODE", "TRACK1", "TRACK2", "TRACK3", "TRACK4"]
def _row1_u(i):
    """Evenly spaced across the faceplate inside the EDGE margin."""
    first = EDGE + FSW_SLOT_W / 2.0
    last  = FP_W - EDGE - FSW_SLOT_W / 2.0
    return first + (last - first) * i / (len(_ROW1) - 1)

# Shared vertical centre-line for the LEFT control column (7" screen + LED ring +
# encoder): the gap between pedals 1 and 2, so the whole column sits above that gap.
COL_U = (_row1_u(0) + _row1_u(1)) / 2.0

# CLEAR/BANK ride row 2, aligned in u with UNDO (i=2) and MODE (i=3).
PEDALS = [(_ROW1[i], _row1_u(i), PEDAL_ROW1_V) for i in range(8)] + [
    ("CLEAR", _row1_u(2), PEDAL_ROW2_V), ("BANK", _row1_u(3), PEDAL_ROW2_V)]

# Front-lip screws: outer two land in the GAPS between pedals 1-2 and 7-8 (clear of
# every foot-plate), the middle one on centre. Shared by the lid lip and the front wall.
FRONT_SCREW_U = [COL_U, FP_W / 2.0, (_row1_u(6) + _row1_u(7)) / 2.0]

# Status-LED pedals: the 4 tracks + CLEAR + BANK (REC/PLAY has no LED -- the encoder
# ring serves it; it's the first LED position in row 1, removed).
def _has_led(label):
    return label in ("CLEAR", "BANK") or label.startswith("TRACK")

# Silkscreen label text per control (REC/PLAY stacks on two lines; tracks show the number).
def _silk_lines(label):
    if label == "REC/PLAY":
        return ["REC/", "PLAY"]
    if label.startswith("TRACK"):
        return []                 # tracks are identified by the meter screen, no silk text
    return [label]

def platform_h(v):
    """Platform shelf height that lands the ASP-1 foot-plate ~flush with the sloped
    top at depth v (FOOTPLATE_PROUD: 0 = flush, <0 = slightly recessed)."""
    return lid_top_z(v) + FOOTPLATE_PROUD - ASP1_H

def faceplate_holes():
    """All faceplate features. Pedal slots have NO mounting holes (the pedals
    stand on internal welded platforms). u=player L->R, v=front->rear."""
    cuts, engr = [], []
    # --- 10 pedal slots (two rows); a status LED above the TRACK pedals only -
    for label, u, v in PEDALS:
        cuts.append({"kind": "rect", "u": u - FSW_SLOT_W/2, "v": v - FSW_SLOT_D/2,
                     "w": FSW_SLOT_W, "h": FSW_SLOT_D, "r": 0.0, "ref": label})  # square: max corner clearance
        led = _has_led(label)   # (slot cutouts below replace the old per-pedal LED holes;
                                #  the flag still sets the label offset, unchanged)
        # silkscreen label ABOVE the pedal (rear side); every line is drawn at
        # EXACTLY the pill width (LED_SLOT_W) so labels and LED pills read as one
        # family of bars: common cap height, width factor forces the advance.
        lines = _silk_lines(label)
        if not lines:                                  # tracks carry no silk text
            continue
        v_lbl = v + FSW_SLOT_D/2 + (LED_GAP + 12.0 if led else 8.0)  # labelled pills get extra air
        infos = []                                     # (text, width-factor, displayed width)
        for ln in lines:
            est_w = SILK_H * len(ln) * SILK_CW         # natural width at the common height
            infos.append((ln, LED_SLOT_W / est_w, LED_SLOT_W))
        left_x = u - max(d for _, _, d in infos) / 2.0   # multiline: flush-left, block centred
        for k, (ln, wf, disp_w) in enumerate(infos):
            vpos = v_lbl + (len(lines)-1-k)*(SILK_H*1.15)
            if len(lines) > 1:                         # multiline (REC/PLAY) -> left-aligned
                engr.append({"u": left_x, "v": vpos, "h": SILK_H, "s": ln, "wf": wf, "halign": "left"})
            else:                                      # single line -> centred on the pedal
                engr.append({"u": u, "v": vpos, "h": SILK_H, "s": ln, "wf": wf, "halign": "center"})
    # --- LED diffuser slots: ONE small pill window per indicator pedal, on the
    #     old status-LED centre-line (a single-LED WS2812B board under each,
    #     VHB-taped to the faceplate underside; milky PMMA pill diffuser set into
    #     the slot). Full-round ends: corner r = LED_SLOT_H/2.
    for label, u, v in PEDALS:
        if not _has_led(label):
            continue
        vc = v + FSW_SLOT_D/2 + LED_GAP              # same centre-line the LED holes used
        cuts.append({"kind": "rect", "u": u - LED_SLOT_W/2, "v": vc - LED_SLOT_H/2,
                     "w": LED_SLOT_W, "h": LED_SLOT_H, "r": LED_SLOT_H/2,
                     "ref": label + "_LEDSLOT"})
    # --- screens: top edges aligned on SCREEN_TOP_V ------------------------
    cuts.append({"kind": "rect", "u": COL_U - SMALL_W/2.0, "v": SCREEN_TOP_V - SMALL_H, "w": SMALL_W, "h": SMALL_H, "ref": "SCREEN_7IN"})
    s16_uc = (_row1_u(4) + _row1_u(7)) / 2.0    # centre over the 4 track pedals (row-1 right group)
    cuts.append({"kind": "rect", "u": s16_uc - BIG_W/2.0, "v": SCREEN_TOP_V - BIG_H, "w": BIG_W, "h": BIG_H, "ref": "SCREEN_16IN"})
    # --- encoder + diffused ring: on the CLEAR/BANK height centre line, and on
    #     COL_U -- the SAME vertical centre-line as the 7" screen (pedal 1/2 gap) -
    enc_v = PEDAL_ROW2_V                 # CLEAR/BANK height centre
    enc_u = COL_U                        # shared left-column centre-line (7" screen + ring)
    cuts.append({"kind": "ring",   "u": enc_u, "v": enc_v, "od": RING_OD, "id": RING_ID, "ref": "RING"})
    cuts.append({"kind": "circle", "u": enc_u, "v": enc_v, "d": D_ENC, "ref": "ENCODER"})
    # NOTE: no LEDs flank the encoder -- like the reference, the ring stands alone
    # (it is also the REC/PLAY indicator). Power state shows on the rear power button.
    # The lid bolts to the body through its DOWN-TURNED SKIRT FLANGES (front lip +
    # sides + rear), NOT through this top face -- those screw holes live on the
    # flanges, added in dxf_faceplate / the render. So nothing more on the top here.
    return cuts, engr

def rear_holes():
    """Rear WALL features (welded, version-independent): the connector WINDOW (closed by a
    swappable I/O sub-panel), bolt holes around it, fixed exhaust vents and an earth stud.
    The version-specific connectors live on the sub-panel, NOT the wall. u=0..W, z=0..REAR_WALL_H."""
    u, z = REAR_WIN_U, REAR_WIN_Z
    cuts = [{"kind": "rect", "u": u-REAR_WIN_W/2, "v": z-REAR_WIN_H/2,
             "w": REAR_WIN_W, "h": REAR_WIN_H, "ref": "IO_WINDOW"}]
    for du in (-REAR_WIN_W/2-9, REAR_WIN_W/2+9):                 # 4 bolt holes around the window
        for dz in (-REAR_WIN_H/2-9, REAR_WIN_H/2+9):
            cuts.append({"kind": "circle", "u": u+du, "v": z+dz, "d": D_M3, "ref": "IO_BOLT"})
    # Evenly fill the rear wall: matching margins (window left margin = vent right margin = EDGE,
    # and the window->vents gap = EDGE), with the vent columns evenly pitched across the span.
    sl = VENT_SLOT[0]
    v_l = u + REAR_WIN_W/2 + EDGE                                # first vent column (EDGE gap after window)
    v_r = W - EDGE                                               # last column's right edge (EDGE margin)
    ncol = max(2, round((v_r - v_l - sl) / (sl + 8.0)) + 1)
    cp = (v_r - v_l - sl) / (ncol - 1)                          # exact pitch so the block fills v_l..v_r
    cuts.append({"kind": "circle", "u": (u+REAR_WIN_W/2 + v_l)/2.0, "v": REAR_WALL_H/2.0,
                 "d": D_GND, "ref": "EARTH_STUD"})              # earth stud centred in the window->vents gap
    vr = 7                                                       # rows, centred on the wall mid-height
    vz0 = REAR_WALL_H/2.0 - ((vr-1)*VENT_PITCH + VENT_SLOT[1])/2.0
    cuts += _vent_array(u0=v_l, z0=vz0, cols=ncol, rows=vr, cp=cp)
    return cuts

def rear_panel_holes(variant):
    """Connector cutouts for the swappable rear I/O sub-panel, in PANEL-LOCAL coords
    (origin = window centre). 'pi' = on-board Pi; 'nopi' = external host (screens out)."""
    hw, hh = D_HDMI; uw, uh = D_USB
    pwr = [{"kind": "circle", "u": -120, "v": 0, "d": D_BARREL, "ref": "9V_DC"},
           {"kind": "circle", "u":  -82, "v": 0, "d": D_PWRBTN, "ref": "POWER"},
           {"kind": "circle", "u":  -44, "v": 0, "d": D_FUSE,   "ref": "FUSE"}]
    if variant == "pi":
        # The Raspberry Pi rides a riser so its rear-edge port stack reaches the window;
        # ONE block exposes that stack directly (2x USB-A + Gigabit Ethernet), centred.
        pio_w, pio_h = D_PI_IO
        return pwr + [
            {"kind": "rect", "u": -pio_w/2, "v": -pio_h/2, "w": pio_w, "h": pio_h, "ref": "PI_USB_ETH"}]
    return pwr + [        # nopi: external host -> 2x HDMI (16"+7") + 2x USB touch
        {"kind": "rect", "u":   2-hw/2, "v": -hh/2, "w": hw, "h": hh, "ref": "HDMI_16"},
        {"kind": "rect", "u":  42-hw/2, "v": -hh/2, "w": hw, "h": hh, "ref": "HDMI_7"},
        {"kind": "rect", "u":  84-uw/2, "v": -uh/2, "w": uw, "h": uh, "ref": "USB_TOUCH_16"},
        {"kind": "rect", "u": 120-uw/2, "v": -uh/2, "w": uw, "h": uh, "ref": "USB_TOUCH_7"}]

def dxf_rear_panel(path, variant):
    """Swappable rear I/O sub-panel: a plate that closes the rear WINDOW (with a bolt-on
    overlap) carrying the version's connector cutouts. Built per variant ('pi'/'nopi')."""
    doc = _doc(); msp = doc.modelspace(); ov = 15.0   # overlap: bolts (+9 from window) clear the panel edge by >=4mm
    pw, ph = REAR_WIN_W + 2*ov, REAR_WIN_H + 2*ov
    _poly(msp, [(-pw/2,-ph/2), (pw/2,-ph/2), (pw/2,ph/2), (-pw/2,ph/2)], "CUT")
    _emit(msp, rear_panel_holes(variant))
    for du in (-REAR_WIN_W/2-9, REAR_WIN_W/2+9):                 # bolt holes match the wall
        for dz in (-REAR_WIN_H/2-9, REAR_WIN_H/2+9):
            _circle(msp, du, dz, D_M3)
    label = "Pi: 9V+btn+fuse+USB-A x2" if variant == "pi" else "no-Pi: 9V+btn+fuse+HDMI x2+USB-touch x2"
    _text(msp, -pw/2+4, ph/2+6, 6, f"VAMP REAR I/O PANEL ({variant})  2.0mm  x1  {label}  PROVISIONAL", "NOTE")
    doc.saveas(path); return {}

def _vent_array(u0, z0, cols, rows, cp=None):
    """A block of louvre slots; returns rect features on the VENT layer. cp = column pitch."""
    sl, sw = VENT_SLOT
    if cp is None:
        cp = sl + 8.0
    out = []
    for r in range(rows):
        for c in range(cols):
            out.append({"kind": "rect", "u": u0 + c * cp, "v": z0 + r * VENT_PITCH,
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
        assert ph > T + 2.0, f"PLATFORM_HEADROOM: platform {ph:.1f} mm too low at v={v:.0f}"
        proud = ph + ASP1_H - lid_top_z(v)         # how far the pedal stands proud
        assert -8.0 <= proud <= ASP1_H, f"PLATFORM_HEADROOM: pedal proud {proud:.1f} mm at v={v:.0f}"

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

    # 8. every rear-wall feature fits inside the (lowered) rear wall (u 0..W, z 0..REAR_WALL_H)
    for c in rear:
        if c["kind"] == "circle":
            r = c["d"] / 2.0
            lo_u, hi_u, lo_z, hi_z = c["u"]-r, c["u"]+r, c["v"]-r, c["v"]+r
        else:
            lo_u, hi_u, lo_z, hi_z = c["u"], c["u"]+c["w"], c["v"], c["v"]+c["h"]
        assert 0 <= lo_u and hi_u <= W and 0 <= lo_z and hi_z <= REAR_WALL_H, \
            f"REAR_BOUNDS: {c['ref']} outside the rear wall (z<= {REAR_WALL_H:.0f})"
    return True

def _bottom_vents_local(bw, bd):
    """Intake-vent block in the clear gap between the front and CLEAR/BANK platform
    rows (air enters here, crosses the boards, exits the rear-wall vents)."""
    sl, sw = VENT_SLOT
    cols, rows = 6, 5
    gap_y = (PEDAL_ROW1_V + FSW_SLOT_D/2 + PLATFORM_MARGIN +
             PEDAL_ROW2_V - FSW_SLOT_D/2 - PLATFORM_MARGIN) / 2.0
    u0, v0 = bw/2 - (cols*(sl+14))/2, gap_y - (rows*VENT_PITCH)/2
    out = []
    for r in range(rows):
        for c in range(cols):
            out.append({"kind": "rect", "u": u0 + c*(sl+14), "v": v0 + r*VENT_PITCH,
                        "w": sl, "h": sw, "ref": "VENT", "layer": "VENT"})
    return out


def _bottom_vents():
    return _bottom_vents_local(W - 2*T, D - 2*T)

# --- internal board mounting -------------------------------------------------
# Bottom-plate frame: x = width (0..W-2T), y = depth (0..D-2T, 0 = front).
# The pedal platforms hang from the walls at the front + CLEAR/BANK rows, so the
# REAR strip of the bottom plate is the clear floor for the electronics. ONE main
# board (V1 loopy_pedal_main, or the Pi-main with a Raspberry Pi riding its GPIO)
# mounts there on M3 standoffs (>= STANDOFF_H for airflow). Same hole pattern both
# ways so one chassis fits either version. 16" screen above is shallow -> clears it.
# Offset 25 mm off the rear I/O window axis (REAR_WIN_U), AWAY from the CLEAR/BANK
# platform column: the Pro Micro's USB socket faces that platform, and centring the
# board left only ~6 mm to it — not enough for a USB-C/micro plug body. The offset
# buys ~37 mm to the platform slot edge. Sat forward of the rear wall to leave room
# for the Raspberry Pi, which (in the Pi build) tucks behind the board with its port
# cluster out the window. The mid-row platforms clear the rear strip, so depth is
# generous. (Only the Pi needs to stay centred on the window — see pi_mount.)
BOARD_U = REAR_WIN_U - 25.0
def board_mounts():
    bw, bd = W - 2*T, D - 2*T
    return [("MAIN_BOARD", BOARD_U, bd - 145.0, BOARD_HOLES)]

# Pi build only: the Raspberry Pi rides four M2.5 risers (PI_RISER_H tall) so its rear-edge
# USB/Ethernet stack lines up with the rear I/O window. It sits at the wall, centred on the
# window, ports facing out -- above and behind the main board, so the two never clash.
# Returns (centre_u, centre_depth, (u_span, depth_span)) for the 58x49 Pi 4 hole pattern.
# NOTE the Pi 4's hole pattern is NOT centred on the board: along the 85 mm length the
# holes sit 3.5/61.5 mm from the SD edge, i.e. the pattern centre is 10 mm SD-ward of the
# board centre; the PCB port edge is centre_depth + 52.5 and the connector faces ~4 mm
# beyond that. Depth is bounded by the rear SUB-PANEL, which bolts against the wall's
# INSIDE face (plate T mm thick): the PCB edge must stop short of that plate -- only the
# connector bodies pass through its port-block cutout. bd - 56 leaves the PCB edge
# ~1.4 mm clear of the plate and the connector faces recessed ~1.4 mm inside the wall's
# outer skin: nothing protrudes past the panel. (bd - 42 put the PCB 8+ mm out through
# the window; even bd - 52 left the PCB crossing the sub-panel plane.)
def pi_mount():
    bd = D - 2*T
    return (REAR_WIN_U, bd - 56.0, (PI_HOLES[1], PI_HOLES[0]))   # 49 across u, 58 along depth

# External Pololu D24V90F5 buck (40.6 x 20.3 mm, 4x M2 at 35.6 x 15.2 mm) — the add-on that
# makes 5V for the Pi + screens (the in-production board is untouched). Mounted on standoffs
# in the rear airflow bay, to the right of the Pi/main-board column.
BUCK_HOLES = (35.6, 15.2)
def buck_mount():
    bd = D - 2*T
    return (REAR_WIN_U + 125.0, bd - 60.0, BUCK_HOLES)

# ===========================================================================
# DXF  (ezdxf)
# ===========================================================================

def _doc():
    import ezdxf
    doc = ezdxf.new("R2018", setup=True)
    doc.units = 4  # mm
    # bold face for printed legends (the overlay shop substitutes their Arial
    # Bold; the DXF style just names it -- thicker strokes than the default)
    doc.styles.add("SILKBOLD", font="arialbd.ttf")
    doc.layers.add("CUT", color=7)
    doc.layers.add("BEND", color=4, linetype="DASHED")
    doc.layers.add("ENGRAVE", color=3)
    doc.layers.add("VENT", color=7)
    doc.layers.add("WELD", color=6)
    doc.layers.add("NOTE", color=8)
    doc.layers.add("SILK", color=5)    # silkscreen (printed labels)
    return doc

def _circle(msp, x, y, d, layer="CUT"):
    msp.add_circle((x, y), d / 2.0, dxfattribs={"layer": layer})

def _poly(msp, pts, layer="CUT", closed=True):
    msp.add_lwpolyline(pts, close=closed, dxfattribs={"layer": layer})

def _rrect(msp, x, y, w, h, r=R_FILLET, layer="CUT"):
    r = max(0.0, min(r, w / 2.0, h / 2.0))
    if r == 0.0:
        _poly(msp, [(x, y), (x+w, y), (x+w, y+h), (x, y+h)], layer); return
    b = math.tan(math.radians(22.5))      # bulge for a 90 deg corner fillet (NOT 45 -> that is a 180 deg bump)
    pts = [(x+r, y, 0.0), (x+w-r, y, b), (x+w, y+r, 0.0), (x+w, y+h-r, b),
           (x+w-r, y+h, 0.0), (x+r, y+h, b), (x, y+h-r, 0.0), (x, y+r, b)]
    msp.add_lwpolyline(pts, format="xyb", close=True, dxfattribs={"layer": layer})

def _text(msp, x, y, h, s, layer="ENGRAVE", wf=1.0, halign="left"):
    from ezdxf.enums import TextEntityAlignment
    al = TextEntityAlignment.CENTER if halign == "center" else TextEntityAlignment.LEFT
    attrs = {"layer": layer, "width": wf}
    if layer == "SILK":
        attrs["style"] = "SILKBOLD"          # legends print BOLD
    msp.add_text(s, height=h, dxfattribs=attrs).set_placement((x, y), align=al)

def _emit(msp, feats, ox=0.0, oy=0.0):
    for f in feats:
        layer = f.get("layer", "CUT")
        x, y = f["u"] + ox, f["v"] + oy
        if f["kind"] == "circle":
            _circle(msp, x, y, f["d"], layer)
        elif f["kind"] == "ring":
            _circle(msp, x, y, f["od"], layer); _circle(msp, x, y, f["id"], layer)
        elif f["kind"] == "rect":
            r = f.get("r", 0.0 if layer in ("ENGRAVE",) else R_FILLET)
            _rrect(msp, x, y, f["w"], f["h"], r=r, layer=layer)

# ---- parts -----------------------------------------------------------------

def _mirror_u(feats, width):
    """Mirror a feature list across width/2 (u -> width-u) so the flat pattern matches
    the geometry, whose canonical (7"-left) orientation is baked in by a Y-mirror."""
    out = []
    for c in feats:
        c = dict(c)
        if c["kind"] == "rect":
            c["u"] = width - (c["u"] + c["w"])
        else:
            c["u"] = width - c["u"]
        out.append(c)
    return out

def dxf_faceplate(path):
    """REMOVABLE LID (top plate), developed flat = a simple rectangle: the sloped top
    plate (all cutouts) + a down-turned FRONT LIP (screws into the front wall) + a REAR LAP
    (folds onto the transition shoulder, screws DOWN into PEMs). The SIDES are on the base;
    the lid drops in and rests on the side-wall top edges. NOTE: the front-lip hole sits
    close to the fold (12mm front) -- laser + tap after bending (see H_FRONT)."""
    doc = _doc(); msp = doc.modelspace()
    ffl, rl = LID_FRONT_FL, LRL
    PW, PV = FP_W, FP_V
    LW, ox = LID_W, LID_OX               # full-width blank; schedule content offset inside it
    yr0 = ffl + PV                       # rear fold (top plate -> rear lap)
    yr1 = yr0 + rl
    _poly(msp, [(0, 0), (LW, 0), (LW, yr1), (0, yr1)], "CUT")
    _poly(msp, [(0, ffl), (LW, ffl)], "BEND", closed=False)                # front lip fold (FULL width)
    _poly(msp, [(0, yr0), (LW, yr0)], "BEND", closed=False)                # rear lap fold (FULL width)

    cuts, _engr = faceplate_holes()                   # canonical layout, 7" left
    _emit(msp, cuts, ox=ox, oy=ffl)
    # legends are NOT silkscreened on the metal -- they live on a printed adhesive overlay
    # (dxf_overlay / vamp_overlay). Keeps the metal a plain cut+bend+powder part (cheap).
    for u in FRONT_SCREW_U:
        _circle(msp, ox + u, ffl/2.0, D_M4)                                # front lip -> front wall (horizontal)
    for u in (PW*0.18, PW*0.5, PW*0.82):
        _circle(msp, ox + u, SEAM_M4_V, D_M4)                             # rear lap -> transition (concentric with the flange PEM row)
    _text(msp, 10, yr1+8, 8, f"VAMP LID  2.0mm  x1  top plate + front lip + rear lap (= {180-(SLOPE_ANGLE+TRANS_ANGLE):.0f}deg); rests on the base side walls; no top screws; legends on printed OVERLAY (see vamp_overlay); FOLD with the DRAWN side as the OUTSIDE face (canonical mirror: encoder lands on the player's LEFT)", "NOTE")
    doc.saveas(path)
    return {"blank": (LW, yr1)}

def dxf_overlay(path):
    """PRINTED ADHESIVE TOP-PLATE OVERLAY -- replaces silkscreen. A polycarbonate/vinyl
    graphic bonded to the faceplate: BLACK field, WHITE legends, apertures die-cut to match
    the metal cutouts. Goes to a label/overlay printer, NOT the sheet-metal shop -- so the
    metal stays a plain cut+bend+powder part and there is no per-screen silkscreen setup."""
    doc = _doc(); msp = doc.modelspace()
    _poly(msp, [(0, 0), (FP_W, 0), (FP_W, FP_V), (0, FP_V)], "CUT")     # overlay outline (top-plate face)
    cuts, engr = faceplate_holes()
    _emit(msp, cuts, ox=0, oy=0)                                        # die-cut apertures (match the metal)
    for e in engr:
        _text(msp, e["u"], e["v"], e["h"], e["s"], layer="SILK",       # WHITE legend on the print
              wf=e.get("wf", 1.0), halign=e.get("halign", "left"))
    _text(msp, 10, FP_V + 8, 8, "VAMP TOP OVERLAY  printed adhesive (polycarbonate/vinyl); BLACK field + WHITE legend; die-cut apertures; bonded to the faceplate (no silkscreen on metal)", "NOTE")
    doc.saveas(path); return {}

def dxf_base(path):
    """ONE-PIECE BASE developed as a SINGLE flat blank: the bottom plate in the centre,
    with the FRONT, REAR and both SIDE walls as flaps that fold UP 90 deg on the four
    bottom edges (folding up from the flat bottom works at any front height). Corners
    are welded butt seams with a small relief hole each. The rear flap has a SECOND fold
    = the transition shoulder. The lid drops in on top, screwed at the front + rear."""
    doc = _doc(); msp = doc.modelspace()
    BW, BD = W - 2*T, D - 2*T               # bottom plate (folds up to ~W x D outer)
    # Exact bend allowance: each flap's flat extent = wall height - the 90-deg bend
    # deduction (T + K*T), so the folded OUTER dimensions come out at nominal.
    bdd = DEV90                              # exact 90-deg development (issue #237)
    Hf = H_FRONT - bdd
    Hr = HR_FLAT                             # rear web from the seam solver: the flange
    Ht = HT_FLAT                             # outer lands ONE SHEET below the lap outer
    rrel = T + 1.0                          # small bend-relief radius at each corner
    LIPR_R = 3.0                            # lip-bend relief radius: a cove TANGENT
                                            # to the top edge AND the front edge
                                            # (mirrors the lid lip's roll)
    tan_a, tan_th = math.tan(_ra), math.tan(_rth)
    # side-wall wedge top, FRONT segment: ON the lid underside plane, anchored at
    # the front wall outer top corner (solver Z = -DEV90, i.e. flat y = -bdd -- the
    # solver frame's origin is the front BEND LINE, same axis as the flat's y)
    shf_f = lambda y: (H_FRONT + (y + bdd) * tan_a) - bdd
    # REAR segment: FLUSH on the transition FLANGE underside (two sheets below the
    # lap outer skin) so the full-width flange rests on the wedge tops with no gap.
    # RIDGE_Z is already in the flat-y frame -- adding bdd here drew the whole
    # segment ~0.87 low (caught by hand-editing the Fusion model).
    shf_r = lambda y: (RIDGE_Y - (y - RIDGE_Z) * tan_th
                       - 2.0 * T / math.cos(_rth)) - bdd
    # the two top segments meet in a single CREASE (no apex step): the flange
    # seat plane extended forward until it intersects the lid underside plane
    y_x = ((RIDGE_Y - 2.0 * T / math.cos(_rth) + RIDGE_Z * tan_th
            - H_FRONT - bdd * tan_a) / (tan_a + tan_th))
    _hyp = math.hypot(1.0, tan_a)
    h_F = (shf_f(0.0) + tan_a * LIPR_R - LIPR_R * _hyp)   # cove mouth on the front edge
    y_T = LIPR_R * (1.0 - tan_a / _hyp)                   # tangency depth on the top line
    h_T = shf_f(y_T)                                      # tangency height (on the line)
    lb  = math.tan(math.radians(90.0 - SLOPE_ANGLE) / 4.0)  # cove bulge (sweep 90-slope)
    fext  = (LID_W - BW) / 2.0              # flange side extension past the wall webs
    # the REAR flap is FULL OUTER WIDTH (like the lid): it folds up OUTSIDE the
    # side walls' rear edges and covers the corner seam from the back. The side
    # wedges stop a hair short of the rear wall's inner face, and the flap's
    # overhangs start a ROOT RELIEF above the fold band (beyond the bottom plate
    # there is nothing for the band to wrap -- same rule as any wing root).
    y_edge = BD - 0.15                      # side wedge rear edge (clears the rear
                                            # wall inner face at BD - 0.089)
    ROOT_REL = 2.6                          # overhang root relief past the rear
                                            # fold band (BA90/2 = 2.09 + margin)
    CORNER_R = 2.0                          # fillet where the wedge top meets it
    h_x = shf_f(y_x)                        # crease height (= shf_r(y_x))
    h_corner = shf_r(y_edge)                # wedge top at the rear edge

    # ---- one closed outer CUT contour (CCW): bottom + 4 fold-up flaps; the side flaps
    #      run the full edge and BUTT the front/rear flaps at the corners. The rear
    #      flap's FLANGE section is FULL OUTER WIDTH (steps out at the hinge) so it
    #      seats on the side-wall wedge tops; the wedge tops carry bend-radius
    #      reliefs for the lid's lip and lap folds (issue #237). --------------------
    turn = math.radians(90.0 - TRANS_ANGLE)     # corner turn: wedge top -> rear edge
    ft = CORNER_R * math.tan(turn / 2.0)        # fillet tangent setback
    fb = math.tan(turn / 4.0)                   # fillet bulge (CCW round-off)
    ax = h_corner + ft * math.sin(_rth)         # tangent on the wedge-top slope
    ay = y_edge - ft * math.cos(_rth)
    bx = h_corner - ft                          # tangent on the rear edge
    outline = [
        (0, -Hf), (BW, -Hf), (BW, 0),                                  # FRONT flap
        (BW+h_F, 0, lb), (BW+h_T, y_T),                               # lip relief cove: tangent
                                                                       # to the front edge, sweeps
                                                                       # up to kiss the top line
        (BW+h_x, y_x),                                                 # RIGHT flap: crease onto
        (BW+ax, ay, fb), (BW+bx, y_edge),                              # the flange seat plane,
        (BW, y_edge),                                                  # edge clear of the rear wall
        (BW, BD+ROOT_REL), (BW+fext, BD+ROOT_REL),                     # REAR flap: FULL OUTER
        (BW+fext, BD+Hr+Ht),                                           # WIDTH from the overhang
        (-fext, BD+Hr+Ht),                                             # roots up -- web + flange
        (-fext, BD+ROOT_REL), (0, BD+ROOT_REL),                        # fold OUTSIDE the side
        (0, y_edge),                                                   # walls' rear edges
        (-bx, y_edge, fb),                                             # LEFT flap: rear edge,
        (-ax, ay), (-h_x, y_x),                                        # fillet, crease
        (-h_T, y_T, lb), (-h_F, 0), (0, 0),                           # lip relief cove
    ]
    msp.add_lwpolyline([(pt + (0.0,))[:3] for pt in outline], format="xyb",
                       close=True, dxfattribs={"layer": "CUT"})

    # ---- bend lines: fold UP 90 on the four bottom edges; rear has a 2nd fold ------
    _poly(msp, [(0, 0), (BW, 0)], "BEND", closed=False)                # front
    _poly(msp, [(0, BD), (BW, BD)], "BEND", closed=False)             # rear
    _poly(msp, [(0, 0), (0, BD)], "BEND", closed=False)               # left
    _poly(msp, [(BW, 0), (BW, BD)], "BEND", closed=False)             # right
    _poly(msp, [(-fext, BD+Hr), (BW+fext, BD+Hr)], "BEND", closed=False)  # rear -> transition (full flange width)

    # ---- corner bend-relief holes + WELD-FREE riveted corners ----------------------
    # The 4 vertical corners join via internal L-brackets (vamp_corner_bracket), pop-riveted
    # through both walls -- NO welding, so the whole shell is instant-quote (cut+bend+powder).
    for (cxr, cyr) in ((0, 0), (BW, 0), (0, BD), (BW, BD)):
        _circle(msp, cxr, cyr, 2*rrel)                                  # corner bend-relief
    # Rivets are placed at the SAME heights (z) on BOTH faces of a corner so a single folded
    # L-bracket lines up with all of them. z = height up the wall; RO = offset along the wall.
    # Only the TALL rear corners get riveted L-brackets. The short 12 mm FRONT corners are
    # already clamped top (lid front-lip screws into the front wall) + bottom (bottom-plate
    # fold ties both walls), so they stay a plain butt+relief corner -- no bracket needed.
    RV = D_M3; RO = CORNER_RO                  # 3.2 mm rivet clearance; offset from the corner
    # heights z are measured from the BOTTOM-PLATE TOP (the bracket rests there), so add T
    # to convert to a wall height above the fold line.
    for sgn, xc in ((+1, 0.0), (-1, BW)):     # +1 left (side flap -x) | -1 right (side flap +x)
        for z in CORNER_ZR_WALL:               # rear-wall leg (3 rivets)
            _circle(msp, xc + sgn*RO, BD + T + z, RV)      # rear-wall face   (flat y = BD + T + z)
        for z in CORNER_ZR_SIDE:               # side-wall leg (2 rivets, staggered)
            _circle(msp, xc - sgn*(T + z), BD - RO, RV)    # side-wall face

    # ---- bottom features: vents + Pi/board M3 standoffs + rubber feet -------------
    _emit(msp, _bottom_vents_local(BW, BD))
    for name, cx, cy, (sx, sy) in board_mounts():
        for dx in (-sx/2, sx/2):
            for dy in (-sy/2, sy/2):
                _circle(msp, cx+dx, cy+dy, D_M3)
        _text(msp, cx - sx/2, cy + sy/2 + 4, 5, name, "NOTE")
    pcx, pcy, (psx, psy) = pi_mount()              # Pi build: 4 riser holes (M2.5) at the Pi pattern
    for dx in (-psx/2, psx/2):
        for dy in (-psy/2, psy/2):
            _circle(msp, pcx+dx, pcy+dy, D_M3)
    _text(msp, pcx - psx/2, pcy + psy/2 + 4, 5, f"PI_RISER x{PI_RISER_H:.0f}mm (Pi build)", "NOTE")
    bkx, bky, (bsx, bsy) = buck_mount()            # external 5V buck (M2 standoffs)
    for dx in (-bsx/2, bsx/2):
        for dy in (-bsy/2, bsy/2):
            _circle(msp, bkx+dx, bky+dy, D_M2)
    _text(msp, bkx - bsx/2, bky + bsy/2 + 4, 5, "BUCK 5V (Pololu D24V90F5)", "NOTE")
    for x in (45, BW-45):
        for y in (45, BD-45):
            _circle(msp, x, y, D_FOOT)
    _emit(msp, platform_foot_holes())              # M3 holes for the 10 pedal-platform feet

    # ---- front wall: lid front-lip screws | rear wall: I/O + transition PEM --------
    for u in FRONT_SCREW_U:
        _circle(msp, u, -Hf*0.5, D_M4)                                 # front-lip screws (match the lid lip)
    io = rear_holes()                                                  # canonical; no mirror
    for c in io:
        c["v"] = BD + c["v"]                                           # rear z -> depth on the flap
    _emit(msp, io)
    for f in (0.18, 0.5, 0.82):
        _circle(msp, BW*f, BD + SEAM_PEM_V, PEM_M4)                    # lid-lap PEM on the transition
                                                                       # (concentric with the lap M4s)

    _text(msp, 8, BD+Hr+Ht+10, 9,
          f"VAMP BASE  2.0mm  x1  bottom + front/rear/sides fold up (bend ded {bdd:.2f}); WELD-FREE: rivet the 4 corners via L-brackets; rear 2nd fold = transition (flange FULL width, seats on the relieved side-wall tops); FOLD with the DRAWN side as the INSIDE face (canonical mirror: encoder lands on the player's LEFT)",
          "NOTE")
    doc.saveas(path); return {"blank": (BW + 2*h_x, BD + Hf + Hr + Ht)}

def dxf_corner_bracket(path, ht, wall_zs, side_zs, tag):
    """Internal L-bracket that joins a vertical corner WITHOUT welding: one leg pop-rivets to
    the rear wall, the other to the side wall. Folded 90 deg. Rivet holes MATCH the base corner
    holes exactly (CORNER_RO from the fold; staggered heights per leg so no two rivets meet)."""
    doc = _doc(); msp = doc.modelspace()
    LEG = CORNER_LEG
    _poly(msp, [(0, 0), (2*LEG, 0), (2*LEG, ht), (0, ht)], "CUT")
    _poly(msp, [(LEG, 0), (LEG, ht)], "BEND", closed=False)             # 90 deg fold between the legs
    for z in wall_zs:
        _circle(msp, LEG - CORNER_RO, z, D_M3)                          # rear-wall leg
    for z in side_zs:
        _circle(msp, LEG + CORNER_RO, z, D_M3)                          # side-wall leg
    _text(msp, 0, ht+6, 6, f"VAMP CORNER BRACKET ({tag})  2.0mm  x2  weld-free corner join; rivet to both walls", "NOTE")
    doc.saveas(path); return {}

def platform_foot_u(sw):
    """The two x-fractions of the foot-flange screws, as offsets from the shelf centre."""
    return (-sw*0.25, sw*0.25)

def platform_foot_holes():
    """M3 holes in the bottom plate for the 10 platform foot-flange screws (front + rear
    in-turned flanges), projected from each pedal onto the horizontal bottom plate."""
    cs = math.cos(math.radians(SLOPE_ANGLE))
    sw = ASP1_W + 2*PLATFORM_MARGIN; sd = ASP1_D + 2*PLATFORM_MARGIN; ff = PLATFORM_FOOT
    out = []
    for _label, u, v in PEDALS:
        vb = v * cs                                # pedal depth projected onto the flat bottom
        for d in platform_foot_u(sw):
            out.append({"kind": "circle", "u": u+d, "v": vb - sd/2 + ff/2, "d": D_M3, "ref": "PLAT_SCR"})
            out.append({"kind": "circle", "u": u+d, "v": vb + sd/2 - ff/2, "d": D_M3, "ref": "PLAT_SCR"})
    return out

def dxf_platform(path, ph, qty, tag):
    """Inner pedal platform: a closed 4-WALL box (skirt) the ASP-1 stands on. The box stays
    WITHIN the pedal footprint; the front & rear walls carry IN-turned foot flanges that are
    SCREWED to the bottom plate (M3) -- no spot welding. A closed box on screwed feet resists
    a stomp far better than an open channel; matters most for the tall CLEAR/BANK platform."""
    doc = _doc(); msp = doc.modelspace()
    sw = ASP1_W + 2*PLATFORM_MARGIN
    sd = ASP1_D + 2*PLATFORM_MARGIN
    # box stands ON the bottom plate (T thick), so its height = ph - T; wall = box - shelf - flange
    h  = max(ph - 3*T, 3.0)                 # wall height (-T bottom plate, -T shelf, -T flange)
    ff = PLATFORM_FOOT
    ox, oy = h, h+ff                        # left/right walls have no flange; front/rear do
    x0, x1 = ox, ox+sw                      # shelf x extents in the flat
    y0, y1 = oy, oy+sd                      # shelf y extents
    # cross outline: shelf + front/rear (wall+flange) arms + left/right (wall only) arms
    _poly(msp, [
        (x0, 0), (x1, 0), (x1, y0),                  # front arm (wall + in-turned flange)
        (x1+h, y0), (x1+h, y1), (x1, y1),            # right wall
        (x1, y1+h+ff), (x0, y1+h+ff), (x0, y1),      # rear arm (wall + in-turned flange)
        (0, y1), (0, y0), (x0, y0),                  # left wall
    ], "CUT")
    for s in ([[(x0,y0),(x1,y0)], [(x0,ff),(x1,ff)],            # front: shelf->wall, wall->flange
               [(x0,y1),(x1,y1)], [(x0,y1+h),(x1,y1+h)],       # rear
               [(x0,y0),(x0,y1)], [(x1,y0),(x1,y1)]]):         # left & right walls (single fold)
        _poly(msp, s, "BEND", closed=False)
    # corner bend-relief at the 4 shelf corners where the front/rear folds cross the
    # side-wall folds. The radius must clear the crossing folds' bend-allowance bands
    # yet stay a band clear of the nearby wall->flange folds at y=ff / y=y1+h -- on
    # the short-walled FRONT platform that caps it below the base's T+1.
    band = math.pi/4 * (RI + KF*T)          # half the flattened 90-deg bend arc
    rrel = min(T + 1.0, h - band)
    assert rrel >= band, f"wall h={h:.2f} too short for corner bend-relief"
    for cx, cy in ((x0, y0), (x1, y0), (x0, y1), (x1, y1)):
        _circle(msp, cx, cy, 2*rrel)
    # M3 screw holes through the two in-turned foot flanges (front + rear)
    cxs = ((x0+x1)/2 + d for d in platform_foot_u(sw))
    for cx in list(cxs):
        _circle(msp, cx, ff/2, D_M3)               # front flange
        _circle(msp, cx, y1+h+ff/2, D_M3)          # rear flange
    _text(msp, x0, y1+h+ff+8, 6,
          f"VAMP PLATFORM {tag}  2.0mm  x{qty}  closed 4-wall box H {ph:.1f}  PROVISIONAL  "
          "M3-screw front+rear foot flanges to bottom; butt-weld 4 corners", "NOTE")
    doc.saveas(path); return {}

def dxf_screen_bracket(path):
    """Rear clamp bracket that retains a bezel monitor from behind (qty per
    screen). Simple L: a face that PEMs to the shell + a return that the monitor
    clamps against. Two sizes noted."""
    doc = _doc(); msp = doc.modelspace()
    bl, bh = 60.0, 30.0
    bf = 24.0                       # PEM flange depth: M4 clinch ring sits >=9mm from the bend
    _poly(msp, [(0, -bf), (bl, -bf), (bl, bh), (0, bh)], "CUT")
    _poly(msp, [(0, 0), (bl, 0)], "BEND", closed=False)
    for x in (15, bl-15):
        _circle(msp, x, -bf/2.0, PEM_M4)
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
    fp = cq.Workplane("XY").box(FP_V, LID_W, T, centered=False)  # X=v, Y=u (full-width lid)
    cuts, _ = faceplate_holes()
    for c in cuts:
        if c["kind"] == "rect":
            c["_rx"], c["_ry"] = c["h"], c["w"]
    return _cut(cq, fp, cuts, lambda u, v: (v, LID_OX + u))

def _rear_flat(cq):
    wall = cq.Workplane("XY").box(W-2*T, REAR_WALL_H, T, centered=False)  # X=u, Y=z
    feats = rear_holes()
    for c in feats:
        if c["kind"] == "rect":
            c["_rx"], c["_ry"] = c["w"], c["h"]
    return _cut(cq, wall, feats, lambda u, v: (u, v))

def _transition_face(cq):
    """The angled transition shoulder, located in the body: a flat facet from the peak
    line (X=FACE_RUN, Z=H_REAR) raked DOWN to the rear-panel top (X=D, Z=REAR_WALL_H).
    +TRANS_ANGLE so the +X (rearward) end DROPS (matches the side-panel profile)."""
    box = cq.Workplane("XY").box(TRANS_LEN, LID_W, T, centered=False)  # X along the facet (FULL width)
    loc = (cq.Location(cq.Vector(FACE_RUN, (W - LID_W) / 2.0, H_REAR))
           * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), TRANS_ANGLE))
    return box.val().moved(loc)

def _platform_solid(cq, ph):
    sw = ASP1_W + 2*PLATFORM_MARGIN
    sd = ASP1_D + 2*PLATFORM_MARGIN
    shelf = cq.Workplane("XY").box(sd, sw, T, centered=(True, True, False)).translate((0,0,ph))
    legf = cq.Workplane("XY").box(T, sw, ph, centered=(True, True, False)).translate((-sd/2+T/2,0,0))
    legr = cq.Workplane("XY").box(T, sw, ph, centered=(True, True, False)).translate((sd/2-T/2,0,0))
    return shelf.union(legf).union(legr)

def build_diffuser_step():
    """LED pill diffuser INSERT (3D-print in clear/milky resin, x6 per console):
    a stadium lens that pushes into the faceplate slot FROM THE INSIDE until its
    shoulder flange seats on the sheet's underside; the lens stands LED_INS_PROUD
    above the outer skin. The single-LED module (hardware/led_strip/ puck or an
    off-the-shelf WS2812B breakout) nests in a shallow pocket on the back and is
    VHB-taped over the flange, which also retains the insert."""
    import cadquery as cq
    lens_l = LED_SLOT_W - LED_INS_CLR
    lens_w = LED_SLOT_H - LED_INS_CLR
    lens_h = T + LED_INS_PROUD
    fl_l = LED_SLOT_W + 2 * LED_INS_FLANGE
    fl_w = LED_SLOT_H + 2 * LED_INS_FLANGE
    lens = cq.Workplane("XY").slot2D(lens_l, lens_w).extrude(lens_h)
    lens = lens.edges(">Z").chamfer(0.3)             # soft glow edge on the proud lip
    ins = lens.union(cq.Workplane("XY").slot2D(fl_l, fl_w).extrude(-LED_INS_FL_T))
    px, py, pd = LED_INS_POCKET                       # LED nest, back face
    ins = ins.cut(cq.Workplane("XY").workplane(offset=-LED_INS_FL_T)
                  .rect(px, py).extrude(pd))
    step = os.path.join(OUT, "vamp_led_diffuser.step")
    stl = os.path.join(OUT, "vamp_led_diffuser.stl")
    cq.exporters.export(ins.val(), step)
    cq.exporters.export(ins.val(), stl)
    return step


def build_ring_diffuser_step():
    """Encoder LED-ring diffuser INSERT (3D-print in clear/milky resin, x1):
    the annular sibling of vamp_led_diffuser -- pushes into the faceplate's ring
    window FROM THE INSIDE, shoulder flange seats on the sheet's underside, and
    an annular pocket on the back nests the NeoPixel Ring 16 (authentic Adafruit,
    44.5mm OD -- verify before printing, clones run 68mm+) so the 16 LEDs glow
    through the lens. Same clearances/proud as the pill insert."""
    import cadquery as cq
    ro = (RING_OD - LED_INS_CLR) / 2.0
    ri = (RING_ID + LED_INS_CLR) / 2.0
    lens = (cq.Workplane("XY").circle(ro).circle(ri)
            .extrude(T + LED_INS_PROUD))
    lens = lens.edges(">Z").chamfer(0.3)
    fo = RING_OD / 2.0 + LED_INS_FLANGE
    fi = RING_ID / 2.0 - LED_INS_FLANGE
    ins = lens.union(cq.Workplane("XY").circle(fo).circle(fi)
                     .extrude(-LED_INS_FL_T))
    # NeoPixel Ring 16 nest: annular recess in the shoulder's back face
    ins = ins.cut(cq.Workplane("XY").workplane(offset=-LED_INS_FL_T)
                  .circle(23.0).circle(16.0).extrude(0.8))
    step = os.path.join(OUT, "vamp_ring_diffuser.step")
    cq.exporters.export(ins.val(), step)
    cq.exporters.export(ins.val(), os.path.join(OUT, "vamp_ring_diffuser.stl"))
    return step


def build_step(write_parts=True):
    import cadquery as cq
    os.makedirs(OUT, exist_ok=True)
    asm = cq.Assembly(name="VAMP")
    # global: X=depth (0 front->D rear), Y=width (0..W), Z=up
    bottom = cq.Workplane("XY").box(D-2*T, W-2*T, T, centered=False).translate((T, T, 0))
    front  = cq.Workplane("XY").box(T, W-2*T, H_FRONT, centered=False).translate((0, T, 0))
    rear   = _rear_flat(cq)
    trans  = _transition_face(cq)
    side   = cq.Workplane("XZ").polyline([(0,0),(D,0),(D,REAR_WALL_H),(FACE_RUN,H_REAR),(0,H_FRONT)]).close().extrude(-T)
    fp     = _faceplate_flat(cq)
    # Canonical layout (7" left) is in the schedule itself -- no mirror. Parts are built
    # in design coords (Y=u, X=v front->rear) and placed directly; the player view is a
    # camera choice in the render/viewer, not a geometry flip.
    addw = lambda shape, name, loc=None: asm.add(
        (shape.val().located(loc) if loc else shape.val()), name=name)

    addw(bottom, "bottom")
    addw(front,  "front")
    rear_loc = (cq.Location(cq.Vector(D - T, T, 0))
                * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), 90)
                * cq.Location(cq.Vector(0,0,0), cq.Vector(0,0,1), 90))
    addw(rear, "rear", rear_loc)
    addw(side, "side_L")
    addw(side, "side_R", cq.Location(cq.Vector(0, W - T, 0)))
    asm.add(trans, name="transition")
    fp_loc = (cq.Location(cq.Vector(0, (W - LID_W) / 2.0, H_FRONT))
              * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), -SLOPE_ANGLE))
    addw(fp, "faceplate", fp_loc)
    # 10 inner platforms under the pedal slots (X = pedal v, Y = pedal u);
    # mid-row (CLEAR/BANK) platforms are taller because the lid is higher there.
    for i, (label, u, v) in enumerate(PEDALS):
        plat = _platform_solid(cq, platform_h(v))
        addw(plat, f"platform_{i}", cq.Location(cq.Vector(v, u + T, 0)))
    # representative loopy_pi_main board on standoffs, rear clear zone (visual stand-in;
    # the fully-detailed KiCad model is rendered in the 3D viewer, not the STEP)
    blk = {"MAIN_BOARD": (BOARD_SIZE[0], BOARD_SIZE[1], 16.0)}
    for name, cx, cy, pat in board_mounts():
        bx, by, bz = blk[name]
        b = cq.Workplane("XY").box(bx, by, bz, centered=(True, True, False)).translate((cy + T, cx + T, STANDOFF_H))
        addw(b, name.lower())
        # the 4 M3 standoff posts under the board (STANDOFF_H tall, on the hole pattern)
        for du in (-pat[0] / 2.0, pat[0] / 2.0):
            for dv in (-pat[1] / 2.0, pat[1] / 2.0):
                post = cq.Workplane("XY").circle(2.75).extrude(STANDOFF_H).translate((cy + T + dv, cx + T + du, 0))
                addw(post, f"{name.lower()}_standoff_u{int(cx + du)}_d{int(cy + dv)}")

    asm.save(os.path.join(OUT, "vamp_assembly.step"))
    if write_parts:
        exp = cq.exporters.export
        # The base is ONE folded blank (see vamp_base.dxf); the assembly STEP shows it
        # in 3D. Per-part STEPs: the removable lid + a representative platform.
        exp(fp.val(), os.path.join(OUT, "vamp_faceplate.step"))
        exp(plat, os.path.join(OUT, "vamp_platform.step"))
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
    P(f"Construction    : welded lower body + REMOVABLE TOP LID (faceplate carries")
    P(f"                  screens + encoder/ring PCB + LEDs; pedals stay on platforms)")
    P("-"*68)
    n1 = sum(1 for _, _, v in PEDALS if v == PEDAL_ROW1_V)
    P(f"Foot pedals     : {len(PEDALS)}x WHOLE Artesia ASP-1 ({ASP1_W:.0f}x{ASP1_D:.0f}x{ASP1_H:.0f}mm)")
    P(f"  layout        : {n1} front row + {len(PEDALS)-n1} centre (CLEAR/BANK), LEDs aligned above")
    P(f"  slot          : {FSW_SLOT_W:.0f}(u) x {FSW_SLOT_D:.0f}(v) mm  [PROVISIONAL]")
    P(f"  platform H    : front {platform_h(PEDAL_ROW1_V):.1f} / mid {platform_h(PEDAL_ROW2_V):.1f} mm "
      f"(foot-plate proud {FOOTPLATE_PROUD:+.0f} mm)  [PROVISIONAL]")
    P(f"Screens         : 7in {SMALL_W:.0f}x{SMALL_H:.0f} (left) | 15.6in {BIG_W:.0f}x{BIG_H:.0f} (right), tops aligned, from behind")
    P(f"Rear I/O        : 9V + btn + fuse + [pi: Pi USB/Ethernet block | nopi: 2xHDMI+2xUSB] + vents + earth")
    P(f"Ventilation     : free area {_vent_free_area(rear_holes())+_vent_free_area(_bottom_vents()):.0f} mm^2 (>= {VENT_FREE_AREA_MIN:.0f}), standoff {STANDOFF_H:.0f}mm")
    P("-"*68)
    P(f"Faceplate cutouts : {len(cuts)}  |  rear-wall cutouts : {len(rear_holes())}")
    area = (W*D + W*L_SLOPE + W*REAR_WALL_H + W*H_FRONT) + 2*(D*(H_FRONT+H_REAR)/2)
    for mat, rho in (("5052 Al", 2.70), ("mild steel", 7.85)):
        P(f"Bare weight     : {area*T*rho/1e6:4.1f} kg  ({mat}, {T:.1f} mm, {area/1e6:.2f} m2)")
    P("="*68)
    return "\n".join(L)

# ===========================================================================
# ANNOTATED LAYOUT SVG  (player view, generated from the schedule)
# ===========================================================================

def layout_svg(path):
    """Draw the faceplate + rear panel in player view (u left->right, front at the
    bottom), straight from faceplate_holes()/rear_holes() so it never drifts. Mirrored
    to match the baked-in canonical orientation (7" on the player's left)."""
    cuts, engr = faceplate_holes()
    M, GAP, fw, fh = 44, 64, FP_W, FP_V
    rear_base = M + fh + GAP + 24
    Wv, Hv = fw + 2*M, rear_base + REAR_WALL_H + 70
    X = lambda u: M + u
    Yf = lambda v: M + (fh - v)            # faceplate: front (low v) at bottom
    Yr = lambda z: rear_base + (REAR_WALL_H - z)
    e = [f'<svg viewBox="0 0 {Wv:.0f} {Hv:.0f}" xmlns="http://www.w3.org/2000/svg" '
         'font-family="Helvetica,Arial,sans-serif">',
         f'<rect width="{Wv:.0f}" height="{Hv:.0f}" fill="#0f1623"/>',
         f'<text x="{M}" y="{M-12}" fill="#94a3b8" font-size="12" font-weight="600">'
         f'VAMP TOP FACEPLATE — player view · {W:.0f} x {D:.0f} x {H_REAR:.0f} mm · '
         f'welded shell · slope {SLOPE_ANGLE:.1f}deg</text>',
         f'<rect x="{M}" y="{M}" width="{fw:.1f}" height="{fh:.1f}" rx="9" '
         'fill="#131c2c" stroke="#5b6b86" stroke-width="2"/>']
    for c in cuts:
        ref = c["ref"]
        if c["kind"] == "rect":
            x, y, w, h = X(c["u"]), Yf(c["v"] + c["h"]), c["w"], c["h"]
            if ref.startswith("SCREEN"):
                lbl = '16" TOUCH - main UI' if "16" in ref else '7" TOUCH - waveform'
                e.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="5" fill="#0c1a24" stroke="#38bdf8" stroke-width="2"/>')
                e.append(f'<text x="{x+w/2:.1f}" y="{y+h/2:.1f}" fill="#4a7f96" font-size="12" text-anchor="middle">{lbl}</text>')
            else:
                fill = "#243149" if ref.startswith("TRACK") else "#1c2740"
                e.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="3" fill="{fill}" stroke="#8aa0c0" stroke-width="1.4"/>')
        elif c["kind"] == "circle":
            r = max(c["d"]/2, 2.0)
            col = ("#22c55e" if ref.endswith("_LED") or ref == "PWR_LED" else
                   "#f59e0b" if ref == "MODE_LED" else
                   "#cbd5e1" if ref == "ENCODER" else "#8aa0c0")
            e.append(f'<circle cx="{X(c["u"]):.1f}" cy="{Yf(c["v"]):.1f}" r="{r:.1f}" fill="{col}"/>')
        elif c["kind"] == "ring":
            e.append(f'<circle cx="{X(c["u"]):.1f}" cy="{Yf(c["v"]):.1f}" r="{c["od"]/2:.1f}" fill="none" stroke="#a855f7" stroke-width="3"/>')
    for lab in engr:
        e.append(f'<text x="{X(lab["u"]+16):.1f}" y="{Yf(lab["v"])+10:.1f}" fill="#9fb0c8" font-size="8" text-anchor="middle">{lab["s"]}</text>')
    # rear panel
    e.append(f'<text x="{M}" y="{rear_base-12:.1f}" fill="#94a3b8" font-size="12" font-weight="600">REAR I/O PANEL — {W:.0f} x {REAR_WALL_H:.0f} mm (lowered; transition shoulder carries the lid-lap screws)</text>')
    e.append(f'<rect x="{M}" y="{rear_base:.1f}" width="{fw:.1f}" height="{REAR_WALL_H:.1f}" rx="6" fill="#131c2c" stroke="#5b6b86" stroke-width="2"/>')
    for c in rear_holes():
        if c.get("layer") == "VENT":
            e.append(f'<rect x="{X(c["u"]):.1f}" y="{Yr(c["v"]+c["h"]):.1f}" width="{c["w"]:.1f}" height="{c["h"]:.1f}" fill="none" stroke="#7c8aa3" stroke-width="1"/>')
        elif c["kind"] == "circle":
            rcol = "#22c55e" if c["ref"] == "EARTH_STUD" else "#cbd5e1"
            e.append(f'<circle cx="{X(c["u"]):.1f}" cy="{Yr(c["v"]):.1f}" r="{max(c["d"]/2,3):.1f}" fill="#0f1623" stroke="{rcol}" stroke-width="1.5"/>')
        elif c["kind"] == "rect":
            e.append(f'<rect x="{X(c["u"]):.1f}" y="{Yr(c["v"]+c["h"]):.1f}" width="{c["w"]:.1f}" height="{c["h"]:.1f}" fill="#0f1623" stroke="#cbd5e1" stroke-width="1.3"/>')
    fy = rear_base + REAR_WALL_H + 28
    e.append(f'<text x="{M}" y="{fy:.1f}" fill="#7c8aa3" font-size="10.5">9V · power · fuse · USB-A x2 · earth stud · vents   |   service: back out the front-lip + rear-lap screws, lift the lid (side wings just locate)</text>')
    e.append(f'<text x="{M}" y="{fy+18:.1f}" fill="#7c8aa3" font-size="10.5">10x ASP-1 pedals on welded inner platforms (PROVISIONAL) · 7 indicator LEDs (REC/PLAY · CLEAR · BANK · TRACK 1-4) · Pi+board mount on the rear bottom plate</text>')
    e.append('</svg>')
    with open(path, "w") as f:
        f.write("\n".join(e) + "\n")
    return path

# ===========================================================================
# SHADED 3D RENDER  (VTK -- populated "all components" hero, optional)
# ===========================================================================

def _render_parts(cq, explode=0.0):
    """(shape, rgb) for the lower body + all representative components. Un-mirrored,
    matches the DXF. explode>0 lifts the LID parts (faceplate + screens + encoder/
    ring + LEDs) straight up while the pedals/platforms/body stay -- shows service."""
    fp_loc = (cq.Location(cq.Vector(0, (W - LID_W) / 2.0, H_FRONT + explode))
              * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), -SLOPE_ANGLE))
    on_fp = lambda wp: wp.val().moved(fp_loc)
    # brighter, more colourful palette (GLTF export darkens, so keep these light)
    ALU=(0.86,0.88,0.92); FACE=(0.40,0.45,0.55); PED=(0.34,0.35,0.40)
    PLAT=(0.55,0.57,0.62); STRIP=(0.92,0.40,0.62)
    P=[]; add=lambda s,c: P.append((s,c))
    add(cq.Workplane("XY").box(D-2*T, W-2*T, T, centered=False).translate((T,T,0)).val(), ALU)
    add(cq.Workplane("XY").box(T, W-2*T, H_FRONT, centered=False).translate((0,T,0)).val(), ALU)
    rl=(cq.Location(cq.Vector(D-T,T,0))*cq.Location(cq.Vector(0,0,0),cq.Vector(0,1,0),90)*cq.Location(cq.Vector(0,0,0),cq.Vector(0,0,1),90))
    add(_rear_flat(cq).val().moved(rl), ALU)
    side=cq.Workplane("XZ").polyline([(0,0),(D,0),(D,REAR_WALL_H),(FACE_RUN,H_REAR),(0,H_FRONT)]).close().extrude(-T)
    add(side.val(), ALU); add(side.val().moved(cq.Location(cq.Vector(0,W-T,0))), ALU)
    add(_transition_face(cq), (0.80,0.82,0.88))      # the angled transition shoulder (body)
    add(on_fp(_faceplate_flat(cq)), FACE)
    # lid folded faces (all lift with the lid): front lip + two side wings (inside the
    # side panels). The rear LAP (folded onto the transition) is placed separately below.
    add(on_fp(cq.Workplane("XY").box(T, LID_W, LID_FRONT_FL, centered=False)
              .translate((0, 0, -LID_FRONT_FL))), FACE)               # front lip (full width;
                                                                      # the lid has NO side wings)
    # rear lap: raked DOWN at the transition angle, resting on the shoulder (lifts with the lid)
    lap_loc = (cq.Location(cq.Vector(FACE_RUN, T, H_REAR + T + explode))
               * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), TRANS_ANGLE))
    add(cq.Workplane("XY").box(LID_REAR_LAP, LID_W, T, centered=False).val().moved(lap_loc), FACE)
    cuts,_=faceplate_holes()
    for label,u,v in PEDALS:
        ph=platform_h(v); add(_platform_solid(cq,ph).val().moved(cq.Location(cq.Vector(v,u+T,0))), PLAT)
        add(cq.Workplane("XY").box(ASP1_D,ASP1_W,ASP1_H,centered=(True,True,False)).translate((v,u+T,ph)).val(), PED)
        # pink/magenta bumper strip across the foot-plate (reference accent)
        add(cq.Workplane("XY").box(16,ASP1_W-8,2,centered=(True,True,False)).translate((v-ASP1_D*0.22,u+T,ph+ASP1_H)).val(), STRIP)
    for c in cuts:
        if c["kind"]=="rect" and c["ref"].startswith("SCREEN"):
            vm=c["v"]+c["h"]/2; um=c["u"]+c["w"]/2; tint=(0.18,0.62,0.55) if "7" in c["ref"] else (0.28,0.40,0.70)
            add(on_fp(cq.Workplane("XY").box(c["h"]-4,c["w"]-4,1.4).translate((vm,um,T+0.7))), tint)
        if c["kind"]=="circle" and c["ref"]=="ENCODER": add(on_fp(cq.Workplane("XY").circle(11).extrude(13).translate((c["v"],c["u"],T))),(0.18,0.18,0.22))
        if c["kind"]=="ring" and c["ref"]=="RING": add(on_fp(cq.Workplane("XY").circle(RING_OD/2).circle(RING_ID/2).extrude(2.2).translate((c["v"],c["u"],T))),(0.78,0.45,1.0))
        if c["kind"]=="circle" and (c["ref"].endswith("_LED") or c["ref"]=="PWR_LED"):
            col=(1.0,0.72,0.20) if c["ref"]=="MODE_LED" else (0.35,1.0,0.50)
            add(on_fp(cq.Workplane("XY").circle(max(c["d"]/2,2.7)).extrude(3.6).translate((c["v"],c["u"],T))), col)
    blk={"MAIN_BOARD":(BOARD_SIZE[0],BOARD_SIZE[1],16,(0.26,0.52,0.92))}
    for name,cx,cy,_ in board_mounts():
        bx,by,bz,col=blk[name]; add(cq.Workplane("XY").box(bx,by,bz,centered=(True,True,False)).translate((cy+T,cx+T,STANDOFF_H)).val(), col)
    # --- fasteners (show how it bolts together; visible from the underside) ----
    bw,bd=W-2*T,D-2*T; SCR=(0.70,0.71,0.76); FEET=(0.10,0.10,0.12); BRASS=(0.74,0.62,0.34)
    gx=lambda yd: yd+T; gy=lambda xw: xw+T          # bottom-plate (width,depth) -> global (X=depth,Y=width)
    perim=[(x,12) for x in (25,bw/2,bw-25)]+[(x,bd-12) for x in (25,bw/2,bw-25)]
    perim+=[(12,y) for y in (bd*0.33,bd*0.66)]+[(bw-12,y) for y in (bd*0.33,bd*0.66)]
    for x,y in perim:                               # M4 bottom-plate screw heads
        add(cq.Workplane("XY").circle(4).extrude(2.6).translate((gx(y),gy(x),-2.6)).val(), SCR)
    for x in (35,bw-35):                            # rubber feet at the corners
        for y in (35,bd-35):
            add(cq.Workplane("XY").circle(9).extrude(7).translate((gx(y),gy(x),-7)).val(), FEET)
    for name,cx,cy,(sx,sy) in board_mounts():       # M3 standoffs under Pi + board
        for dx in (-sx/2,sx/2):
            for dy in (-sy/2,sy/2):
                add(cq.Workplane("XY").circle(3).extrude(STANDOFF_H).translate((gx(cy+dy),gy(cx+dx),0)).val(), BRASS)
    # --- lid fixings: front lip -> Front panel (horizontal); rear lap -> transition (down)
    for u in FRONT_SCREW_U:                          # Front panel, into the lid front lip
        add(cq.Solid.makeCylinder(3.5,2.5,cq.Vector(0,u+T,H_FRONT-5),cq.Vector(-1,0,0)), SCR)
    nrm = cq.Vector(math.sin(math.radians(TRANS_ANGLE)),0,math.cos(math.radians(TRANS_ANGLE)))  # transition outward normal
    # screw station from the seam solver (distance down the facet from the ridge)
    lapx = FACE_RUN + D_SEAM_SCREW*math.cos(math.radians(TRANS_ANGLE))
    lapz = H_REAR - D_SEAM_SCREW*math.sin(math.radians(TRANS_ANGLE)) + T
    for f in (0.18,0.5,0.82):                        # rear LAP screws down into the transition PEM
        add(cq.Solid.makeCylinder(3.3,2.8,cq.Vector(lapx,(W-2*T)*f+T,lapz),nrm), SCR)
    return P    # raw geometry (canonical layout is in the schedule); player view = camera choice

def render_png(path, direction=(-0.32, 0.05, 1.0), explode=0.0):
    """Shaded VTK hero of the populated enclosure (needs cadquery + vtk).
    explode>0 raises the removable lid to show how it comes apart."""
    import cadquery as cq, vtk, numpy as np
    ren=vtk.vtkRenderer(); ren.SetBackground(0.07,0.10,0.16); ren.SetBackground2(0.02,0.03,0.07); ren.GradientBackgroundOn()
    for s,rgb in _render_parts(cq, explode):
        m=vtk.vtkPolyDataMapper(); m.SetInputData(s.toVtkPolyData(0.4,0.25))
        a=vtk.vtkActor(); a.SetMapper(m); p=a.GetProperty()
        p.SetColor(*rgb); p.SetInterpolationToPhong(); p.SetSpecular(0.28); p.SetSpecularPower(28); p.SetDiffuse(0.95); p.SetAmbient(0.30)
        ren.AddActor(a)
    rw=vtk.vtkRenderWindow(); rw.SetOffScreenRendering(1); rw.AddRenderer(ren); rw.SetSize(1700,1150)
    ren.ResetCamera(); cam=ren.GetActiveCamera()
    dv=np.array(direction); dv=dv/np.linalg.norm(dv)
    cam.SetPosition(*(np.array(cam.GetFocalPoint())+dv*cam.GetDistance())); cam.SetViewUp(0,0,1)
    ren.ResetCameraClippingRange(); cam.Zoom(1.45)
    for pos,inten in [((-0.3,-0.8,1.0),1.05),((1.0,0.5,0.5),0.55),((0.2,1.0,0.3),0.45)]:
        l=vtk.vtkLight(); l.SetPosition(*pos); l.SetIntensity(inten); l.SetLightTypeToCameraLight(); ren.AddLight(l)
    rw.Render(); w2i=vtk.vtkWindowToImageFilter(); w2i.SetInput(rw); w2i.Update()
    wr=vtk.vtkPNGWriter(); wr.SetFileName(path); wr.SetInputConnection(w2i.GetOutputPort()); wr.Write()
    # No image flip: the canonical orientation is baked into the geometry (see _render_parts).
    return path

def dxf_ring_disc(path):
    """Metal centre disc that fills the inside of the diffused LED ring (the ring cutout removes a
    full RING_OD hole, so this centre is a separate piece). The EC11 encoder mounts through the
    centre hole and its nut clamps the disc; the knob sits on top. Cut from 2mm sheet."""
    doc = _doc(); msp = doc.modelspace()
    _circle(msp, 0, 0, RING_ID)                 # outline: OD = ring inner diameter
    _circle(msp, 0, 0, D_ENC)                   # encoder bush hole (centre)
    _text(msp, -RING_ID/2, RING_ID/2 + 6, 5, "VAMP LED-RING CENTRE DISC  2.0mm  x1  (encoder clamps it)", "NOTE")
    doc.saveas(path); return {}

# ===========================================================================
# MAIN
# ===========================================================================

DXF_PARTS = [
    ("vamp_faceplate",        dxf_faceplate),
    ("vamp_overlay",          dxf_overlay),  # printed adhesive top-plate graphic (replaces silkscreen)
    ("vamp_base",             dxf_base),     # bottom + front/rear/side walls, ONE folded blank
    ("vamp_platform_front",   lambda p: dxf_platform(p, platform_h(PEDAL_ROW1_V), 8, "FRONT")),
    ("vamp_platform_mid",     lambda p: dxf_platform(p, platform_h(PEDAL_ROW2_V), 2, "MID (CLEAR/BANK)")),
    ("vamp_screen_bracket",   dxf_screen_bracket),
    ("vamp_ring_disc",        dxf_ring_disc),                        # LED-ring centre disc
    ("vamp_corner_bracket_rear",  lambda p: dxf_corner_bracket(p, CORNER_HT, CORNER_ZR_WALL, CORNER_ZR_SIDE, "REAR x2")),
    ("vamp_rear_panel_pi",    lambda p: dxf_rear_panel(p, "pi")),    # swappable rear I/O
    ("vamp_rear_panel_nopi",  lambda p: dxf_rear_panel(p, "nopi")),
]
NO_PDF = {"vamp_platform_front", "vamp_platform_mid", "vamp_ring_disc",
          "vamp_corner_bracket_rear",
          "vamp_rear_panel_pi", "vamp_rear_panel_nopi"}   # minimal parts: DXF only

def main(argv):
    print(report())
    print("\nGeometry assertions ...", end=" ")
    _check()
    print("ALL PASS")
    if "--report" in argv:
        return
    os.makedirs(OUT, exist_ok=True)
    layout_svg(os.path.join(HERE, "vamp_panel_layout.svg"))
    print("\nAnnotated layout: vamp_panel_layout.svg")
    print("DXF flat patterns:")
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
            d = build_diffuser_step()
            print("\nLED diffuser insert (3D print, x6): out/" + os.path.basename(d) + " (+ .stl)")
            r = build_ring_diffuser_step()
            print("Ring diffuser insert (3D print, x1): out/" + os.path.basename(r) + " (+ .stl)")
            p = build_step()
            print("\n3D STEP:\n  " + os.path.relpath(p, HERE) + " (+ per-part .step)")
        except Exception as e:  # pragma: no cover
            print(f"\n(STEP skipped: {e})")
    if "--render" in argv:
        try:
            r = render_png(os.path.join(OUT, "vamp_render.png"))
            print("\nShaded render:\n  out/vamp_render.png")
        except Exception as e:  # pragma: no cover
            print(f"\n(render skipped: {e})")

if __name__ == "__main__":
    main(set(sys.argv[1:]))
