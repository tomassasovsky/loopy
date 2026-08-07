"""Segno — parametric sheet-metal enclosure for the segno Pi loopstation.

Generates a **manufacturing package** for a wedge-shaped floor console modelled on
the "Chewie II" / Sonnit reference (850 x 465 x 100 mm, top sloping toward the
player), housing this repo's standalone build: a Raspberry Pi 4/5 running segno,
the segno_pedal_main board, ten foot pedals, the EC11 encoder + diffused LED ring,
SMD LED-strip status indicators (WS2812B segments behind diffuser slots) and a
7" + 16" touchscreen pair. Branded **Segno**.

Construction (see ../segno_enclosure_design.md and
../../docs/plan/2026-06-27-feat-segno-enclosure-rework-plan.md):

  WELDED LOWER BODY (one rigid tray)        REMOVABLE TOP LID
  - front wall (12) + top flange (ledge)    - faceplate pan (sloped top, all cutouts)
  - rear wall (100) + I/O + vents + flange    + down-turned front/side/rear skirts
  - 2x side panel + top flange (ledge)        (lid screws on the SKIRTS, not the top)
  - bottom plate (welded, vented, Pi/board) - 2x screen-retention bracket
  - 10x inner pedal platform (welded)

Foot controls = ten Cherub WTB-006 footswitches (109.87x76.35, 29.3 mm tall with
anti-slip pads; caliper-measured, see hardware/cherub_wtb006_pedal/) standing
toe-forward on printed pedestals, protruding through ~79x113 mm slots. No
top-face fasteners; pedal wiring stays internal. Service = back out the side +
front-lip screws and lift the lid (screens + ring PCB + LEDs go with it; pedals
stay on their platforms).

Geometry is validated by an **assertion suite** (`_check()`) run before any output,
so "the generator runs" means the geometry is valid (width budget, no overlapping
cutouts, platform head-room, screen depth, vent free-area, bezel overlap).

Outputs (./out, mm): STEP (assembly + per-part), DXF flat patterns
(CUT/BEND/ENGRAVE/WELD/VENT layers), PDF drawing sheets.

Run with the bundled venv (cadquery + ezdxf + matplotlib):
    .venv/bin/python segno_enclosure.py            # check + STEP + DXF + PDF
    .venv/bin/python segno_enclosure.py --report   # report + checks only
    .venv/bin/python segno_enclosure.py --no-step   # DXF + PDF only
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

# --- foot pedals: Cherub WTB-006, caliper-measured 2026-07-28 (issues #358/#360)
# Reference CAD: hardware/cherub_wtb006_pedal/ + the "Cherub WTB-006 Footswitch"
# Fusion doc. The pedal is a WEDGE: wider + taller at the back (cable end),
# mounted toe toward the player (back = rear/high v). Box model uses the MAX
# cross-section; the taper only ever adds clearance.
PEDAL_W      = 76.35          # case width at the back (tapers to 73.08 at the toe)
PEDAL_D      = 109.87         # case length, back to front
PEDAL_BODY_H = 24.9           # case height at the back (slopes to 22.1 at the toe)
PEDAL_PAD_T  = 2.2            # anti-slip pad thickness, bottom AND top
PEDAL_H      = PEDAL_BODY_H + 2*PEDAL_PAD_T   # 29.3 overall standing height
# One horizontal through-screw per side pins the shell halves; each end has a
# 10mm-dia boss + head protruding 3.45mm from the case wall. The bosses pass
# UNDER the faceplate beside the slot -- checked in _check() 3b.
PEDAL_SCREW_BACK   = 23.24    # boss axis, distance from the case BACK edge (v)
PEDAL_SCREW_Z      = 10.10    # boss axis height above the case bottom (excl. pad)
PEDAL_SCREW_BOSS_D = 10.0     # boss/sleeve outer dia at the wall
PEDAL_SCREW_SPAN   = 83.25    # overall width across both screw heads
# Bottom anti-slip pad footprint (from the user-refined Fusion model 2026-07-28):
# inset from the case back edge, used for the pedestal locating pocket.
PEDAL_PAD_W          = 64.61  # bottom pad width
PEDAL_PAD_D          = 90.0   # bottom pad length
PEDAL_PAD_BACK_INSET = 16.43  # pad rear edge inset from the case back edge
FSW_SLOT_W = PEDAL_W + 2.0    # slot width (u) = 78.35, 1.0mm/side. The side screws DON'T
                              # drive this: their bosses duck ~6.6mm under the faceplate
                              # beside the slot (checked in 3b). The case governs, and its
                              # taper means the widest section crossing the plate plane is
                              # only ~76.05 -- real clearance is >=1.15mm/side. Floor is the
                              # lid-drop alignment over 10 pedals (~0.6mm tolerance stack).
FSW_SLOT_CLR_D = 3.0          # HORIZONTAL front+rear clearance target around the pedal.
# FSW_SLOT_D is defined after SLOPE_ANGLE below: the slot lives in the SLOPED
# faceplate but the pedal is HORIZONTAL, so the on-slope slot depth must be the
# horizontal envelope divided by cos(slope) -- without that the projected
# opening was only 0.16mm/side for the WTB-006 (and 0.28mm/side for the ASP-1).
# Pedal seating rule (issue #373, replaces the old FOOTPLATE_PROUD=12 constant):
# the pedal's BODY TOP (case top, under the top pad) sits FLUSH with the sloped
# faceplate surface at the slot's UPPER (rear) rim; only the pad stands above the
# metal. The plate keeps rising for half a slot past the pedal centre, so with the
# old +12 rule the pad top ended up ~0.8 mm BELOW the rear rim and the pedals read
# sunken. Flush-at-rim lands the pad ~15 mm over the slot centre-line -- taller
# front pedestals as a bonus (more insert depth).
PLATFORM_MARGIN = 2.0         # platform shelf overhang past the pedal footprint (stay within the slot)
PLATFORM_FOOT   = 18.0        # base screw inset band (holes ff/2 from the platform edge)
# The pedal platforms are 3D-PRINTED pedestals (they replaced the folded sheet
# boxes): PETG/ASA, solid walls, >=40% infill. M3 brass heat-set inserts
# (~M3 x 5.7 long x 4.6 OD) melt in from BELOW at the base's PLAT_SCR holes
# (bolted from under the floor). The WTB-006 has NO base screws (side screws
# only), so the deck instead gets a shallow LOCATING POCKET for the bottom
# anti-slip pad -- PROVISIONAL retention: gravity + pocket + foot pressure.
INSERT_PILOT_D  = 4.5         # heat-set pilot bore -- sized for M3 5x5 inserts
                              # (5.0 OD knurled, ~0.5mm interference; the old 4.0
                              # suited the 4.6-OD x 5.7 type)
INSERT_DEPTH    = 6.0         # pilot depth (5.0 insert + 1.0 melt allowance)
PLAT_WALL       = 3.0         # printed perimeter wall (cavity hollowing)
PLAT_DECK       = 8.0         # printed top deck (full insert engagement)
POCKET_DEPTH    = 1.2         # bottom-pad locating pocket depth (< PEDAL_PAD_T)
POCKET_CLR      = 0.6         # pocket clearance over the pad footprint (total)
# Light-baffle TUB around the pedal: the pedestal's walls rise from the deck to
# ~1mm under the sloped faceplate with their INNER faces set back SKIRT_SETBACK
# behind the slot cut line -- from above you see ONLY faceplate, and the reveal
# reads as the slot continuing down a dark channel (the wall face), not as a
# ledge or the enclosure interior. Print BLACK (PETG/ASA).
# The side screw bosses (span 83.25) would cross the wall line, so each side
# wall gets a full-height vertical CHANNEL the boss slides down at drop-in --
# it also guides the pedal into the pad pocket.
SKIRT_SETBACK = 0.4           # wall inner face tucked behind the slot cut line
SKIRT_GAP    = 0.3            # wall top to the REAL faceplate underside. Small on
                              # purpose: reads as no gap through the reveal, while
                              # still keeping the lid seated on its flanges, not on
                              # ten printed towers (drift calibrated to ~0.05; if a
                              # tub buzzes on hardware, add felt tape to its top)
# Like POST_FACEDRIFT: the assembled faceplate seats ABOVE lid_top_z's bare
# slope, and by a row-dependent amount -- measured in "Segno console (populated)"
# (the manufacturing source of truth) 2026-07-28: +1.6 over row 1, +0.7 over
# row 2. Without this the skirt gap came out 2.6/1.7 instead of 1.0.
SKIRT_DRIFT_ROW1 = 1.6
SKIRT_DRIFT_ROW2 = 0.5   # was 0.7 at the old row-2 line; re-measured after the #366
                         # rearward move + #373 flush-raise: 0.5 leaves 0.3 mm to the
                         # REAL plate at the tub's rear band (probed in the populated doc)
SKIRT_NOTCH_W = 12.0          # cable notch in the rear tub wall, centred (the
                              # WTB-006 cable leaves the case at the back)
SKIRT_OUT_W  = 88.75          # pedestal footprint W (unchanged from the fence rev)
SKIRT_OUT_D  = 115.37         # pedestal footprint D (rear must clear the posts)
# Tub inner opening = the slot outline (projected flat) + setback. Slot depth is
# an on-slope figure; horizontal = *cos(SLOPE_ANGLE). Defined after SLOPE_ANGLE.
SKIRT_BOSS_CH_W    = 14.0     # boss drop-in channel width (boss dia 10 + 4)
SKIRT_BOSS_CH_HALF = PEDAL_SCREW_SPAN/2 + 0.7   # channel floor: swallows the boss tip
SKIRT_BOSS_CH_X    = PEDAL_D/2 - PEDAL_SCREW_BACK   # +31.695: boss axis, rearward of centre

# --- screens (capacitive touch, mounted from BEHIND; aperture < bezel) --------
BIG_BEZEL  = (359.5, 223.75)  # 15.6" panel BODY (measured): glass 359.5x206.5 edge-to-edge + a
                              # connector strip at the bottom extending the body to 223.75. Used for
                              # slab clearance; note this is ~0.25mm SHORTER than the old 224 so it fits.
BIG_W, BIG_H     = 342.5, 193.0   # 15.6" faceplate APERTURE -- ~0.8mm/side inside the 344.16 x 193.59
                              # ACTIVE area so the faceplate lip overlaps the active edge (no light leak).
                              # The decal (active image, 344.2x193.6) stays; the aperture reveals IT, not
                              # the full glass -- the glass bezel (up to 359.5x206.5) hides behind the lip.
BIG_DEPTH  = 8.0              # thin panel (3-6 mm); HDMI/USB driver board mounts flat inside
SMALL_BEZEL = (165.0, 100.0)  # 7" module outline (APROTII: ears 164x99)
SMALL_W, SMALL_H = 153.75, 85.5   # 7" aperture = the 153.75 x 85.5 visible (active) area; reveals it
                              # fully (mounted from behind), no lip overlap on this screen.
SMALL_DEPTH = 12.0           # 7" panel body 9 mm + connectors (APROTII sheet)

# --- LEDs / encoder -----------------------------------------------------------
# Status indicators = SMD LEDs (WS2812B), NOT through-hole: ONE single-LED
# board per indicator pedal (hardware/led_strip/, 16 x 8 mm puck) stuck to the
# faceplate UNDERSIDE with VHB tape; a WHITE PLA pill diffuser insert sets into
# each slot and glows through. Boards daisy-chain pedal-to-pedal with 3 wires
# (5V/data/GND) on the castellated end pads.
LED_SLOT_H = 6.0          # diffuser-slot height (v); corner r = H/2 -> full round ends
LED_SLOT_W = 60.0         # pill window per indicator pedal (one 5050 diffused behind it)
LED_INS_CLR   = 0.2       # diffuser-insert lateral clearance in the slot (total)
LED_INS_CLR_FDM = 0.5     # ...but into a PRINTED lid, not a laser-cut sheet. A cut
                          # sheet holds the slot to about +/-0.1; an FDM slot comes
                          # out undersize by roughly an extrusion width once flow
                          # and elephant foot are in, so 0.1 a side will not enter.
LED_INS_PROUD = 0.4       # lens stands this far above the outer skin
LED_INS_FLANGE = 3.0      # shoulder overhang past the slot, all around (seats on the
                          # faceplate UNDERSIDE -- the insert pushes in from INSIDE)
LED_INS_FL_T  = 1.5       # shoulder thickness
LED_INS_POCKET = (6.0, 6.0, 0.8)  # LED nest recess in the shoulder's back face
D_ENC     = 7.0      # EC11 encoder bush
RING_OD   = 58.0     # diffused-annulus ring window OD (12 THT LEDs behind)
RING_ID   = 40.0     # ring window ID
N_IND     = 10       # indicator LED pills -- ALL 10 pedals (issue #366). Firmware
                     # chain contract is still indicatorLeds[7]; widening it to 10
                     # is an open firmware change, flagged on the issue.
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
# Main board = the manufactured V1 THT Pro Micro board (the segno_pedal_main THT design,
# git 794eb48; the later SMD 328P+16U2 redesign is discarded). Measured from its KiCad:
# 4x M3 over an 85 x 87 mm rectangle, centred on a 94 x 96 mm outline. Same board (alone)
# in the Base build; in the Pi build a Raspberry Pi rides alongside, linked over USB.
BOARD_HOLES = (85.0, 87.0)    # M3 mount rectangle (measured, THT Pro Micro V1)
BOARD_SIZE  = (94.0, 96.0)    # board outline (for the 3D render)
D_FOOT    = 8.0      # rubber-foot fixing

# --- fasteners ----------------------------------------------------------------
D_M3      = 3.2      # M3 clearance (Pi/board standoffs)
D_M2      = 2.4      # M2 clearance (external buck standoffs)
D_M4      = 4.3      # M4 clearance (bottom plate -> shell)
PEM_M4    = 6.3      # PEM M4 clinch hole (DISTINCT from M4 clearance)
# --- powder-coat masking (annotation only; issue #396) ---
# PEMs are clinched BEFORE the coating line, so the thread has to be plugged. The
# earth stud needs a bare land on both faces or the ring terminal bonds to paint.
MASK_PEM_D = 12.0    # silicone plug / masking disc over an M4 clinch thread
MASK_GND_D = 20.0    # bare bonding land around the M6 earth stud
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
# Pedal slot depth ON THE SLOPE: horizontal envelope / cos(slope) (see pedal block).
FSW_SLOT_D = (PEDAL_D + FSW_SLOT_CLR_D) / math.cos(math.radians(SLOPE_ANGLE))
# Tub inner opening (see the pedal block): slot outline projected flat + setback.
SKIRT_IN_W = FSW_SLOT_W + 2*SKIRT_SETBACK                                    # 79.15
SKIRT_IN_D = FSW_SLOT_D * math.cos(math.radians(SLOPE_ANGLE)) + 2*SKIRT_SETBACK  # 113.67
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

# ===========================================================================
# CUTOUT SCHEDULE  (faceplate local: u=0..FP_W L->R = player's left->right,
#                   v=0..FP_V front->rear)
# ===========================================================================

# Two pedal rows, faithful to the reference: a FRONT row of 8 (4 transport |
# 4 tracks, with a centre gap) and an upper CENTRE pair (CLEAR/BANK). Each pedal
# is a whole Cherub WTB-006 on a printed pedestal; a status LED sits directly ABOVE each
# (aligned in u). CLEAR/BANK ride centre so the 16" screen still fits depth-wise.
EDGE         = 30.0      # uniform edge margin (sides / rear)
FRONT_PEDAL_MARGIN = 10.0 # front-row pedals sit this close to the front edge
LED_GAP      = 12.0      # status-LED offset behind a pedal (toward rear)
SILK_H       = 25.0      # silkscreen cap height -- SAME for every label (a too-wide word
SILK_CW      = 0.66      # gets squished horizontally). bold char advance / cap height.
PEDAL_ROW1_V = FRONT_PEDAL_MARGIN + FSW_SLOT_D / 2.0   # front row pulled to the edge
# 7" screen, LED ring and encoder share ONE vertical centre-line (COL_U, defined
# with the pedal layout below): the gap between pedals 1 and 2.
# SCREEN_TOP_V is FROZEN at the value the console was built around (the screens,
# decals and the Fusion "Segno console (populated)" doc all embody it). When the
# pedal slot deepened for the Cherub WTB-006 (103 -> 112.87), the front gap
# absorbed the change instead of growing the console: FRONT_GAP is now DERIVED
# and asserted >= 40 in _check().
SCREEN_TOP_V = 371.0
FRONT_GAP    = SCREEN_TOP_V - BIG_H - (PEDAL_ROW1_V + FSW_SLOT_D / 2.0)
# CLEAR/BANK sit so their LABEL TOP aligns with the screens' shared top line
# (SCREEN_TOP_V) -- the layout the user approved in the LED trial (issue #366).
# SILK_CAP is the cap-height/em ratio of the label font as it actually renders
# (measured in the "Segno console (populated)" doc; Arial-class bold ~0.717): the
# silk `h` parameter is an em size, so glyph caps top out at v_lbl + SILK_H*SILK_CAP.
SILK_CAP     = 0.7168
PEDAL_ROW2_V = SCREEN_TOP_V - SILK_H * SILK_CAP - (LED_GAP + 12.0) - FSW_SLOT_D / 2.0
# The encoder + LED ring do NOT follow the pedals rearward: the ring would hit the
# 7" screen. It stays on the OLD row-2 centre (the 16"-screen-bottom line).
ENC_V        = (SCREEN_TOP_V - BIG_H) + FSW_SLOT_D / 2.0

# Front row of 8, EVENLY spaced across the faceplate (no 4+4 grouping).
_ROW1 = ["REC/PLAY", "STOP", "UNDO", "MODE", "TRACK1", "TRACK2", "TRACK3", "TRACK4"]
# Pedal centres are FROZEN at the layout the console was built around (originally
# EDGE + slot/2 .. FP_W - EDGE - slot/2 with the 78mm ASP-1 slot). Everything
# downstream hangs off these: COL_U (7" screen/ring/encoder), the 16" aperture
# centre, LED slots, LED-strip PCBs and the Fusion doc. The wider Cherub slot
# (79.35) just eats 0.675mm of the side margin instead of shifting all of that.
ROW1_U_FIRST = 69.0
ROW1_U_LAST  = 777.0
def _row1_u(i):
    """Evenly spaced across the faceplate (frozen span, see above)."""
    return ROW1_U_FIRST + (ROW1_U_LAST - ROW1_U_FIRST) * i / (len(_ROW1) - 1)

# Shared vertical centre-line for the LEFT control column (7" screen + LED ring +
# encoder): the gap between pedals 1 and 2, so the whole column sits above that gap.
COL_U = (_row1_u(0) + _row1_u(1)) / 2.0

# CLEAR/BANK ride row 2, aligned in u with UNDO (i=2) and MODE (i=3).
PEDALS = [(_ROW1[i], _row1_u(i), PEDAL_ROW1_V) for i in range(8)] + [
    ("CLEAR", _row1_u(2), PEDAL_ROW2_V), ("BANK", _row1_u(3), PEDAL_ROW2_V)]

# Front-lip screws: outer two land in the GAPS between pedals 1-2 and 7-8 (clear of
# every foot-plate), the middle one on centre. Shared by the lid lip and the front wall.
FRONT_SCREW_U = [COL_U, FP_W / 2.0, (_row1_u(6) + _row1_u(7)) / 2.0]

# Status-LED pedals: ALL of them (issue #366 -- the LED trial added pills over
# REC/PLAY, STOP, UNDO and MODE; the encoder ring stays as well).
def _has_led(label):
    return True

# Silkscreen label text per control (REC/PLAY stacks on two lines; tracks show the number).
def _silk_lines(label):
    if label == "REC/PLAY":
        return ["REC/", "PLAY"]
    if label.startswith("TRACK"):
        return []                 # tracks are identified by the meter screen, no silk text
    return [label]

def platform_h(v):
    """Platform shelf height that lands the pedal's BODY TOP (case top, under the
    top pad) FLUSH with the faceplate surface at the slot's UPPER (rear) rim --
    pad above the metal (issue #373). The pedal sinks POCKET_DEPTH into the
    deck's locating pocket, so the deck compensates. face_drift closes the gap
    between the bare lid_top_z frame and the REAL plate seating (flush was still
    1.4 mm short at row 1 without it -- measured in the populated doc)."""
    v_rim = v + FSW_SLOT_D / 2.0
    return lid_top_z(v_rim) + face_drift(v_rim) + PEDAL_PAD_T - PEDAL_H + POCKET_DEPTH

def face_drift(v):
    """Measured faceplate seating offset ABOVE the bare lid_top_z slope in the
    "Segno console (populated)" doc -- two-point calibration (+1.6 mm at the row-1
    line, +0.7 mm at the old row-2 line; the same pair behind SKIRT_DRIFT_*).
    lid_top_z uses the tan-slope shortcut, the real plate follows sin + a seating
    offset; this closes the gap where a check needs REAL clearance."""
    return 1.96 - 0.00533 * v

# ---------------------------------------------------------------------------
# FACEPLATE SUPPORT POSTS  (base-anchored props -- issue #292)
# ---------------------------------------------------------------------------
# The shop's STD aluminium is soft 1050 (yield ~105 vs 193 MPa for 5052). The
# faceplate's own perimeter folds already stiffen its edges (~70x at a fold line),
# so the pedal band (close to the front lip) is fine. The ONE zone the perimeter
# folds do NOT reach is the interior just in front of the big 16in aperture: bare
# 2 mm 1050 there dents at only ~11 kg (issue #292). Rather than a rib on the
# VISIBLE top face, TWO vertical posts rise from the base floor to just under that
# zone -- load runs faceplate -> post -> base -> floor. The posts anchor to the
# BASE only; the faceplate bears on their felt caps, so the lid still lifts off and
# NOTHING shows on the top face. Cut+bend only.
POST_V     = 146.5                 # web depth: COMPACT post in the (now very narrow) band between the
                                   # slope-corrected Cherub front-row slots (pad front must stay behind
                                   # v~125.6) and the 15.6in body front (v~147.25) -- was 137 for the
                                   # 103mm ASP-1 slot; re-verify against the populated Fusion doc
POST_U     = [625.0, 726.0]        # in the TRACK LED-slot GAPS (T2-T3 @625, T3-T4 @726) so the pad also
                                   # clears the LED slots; still under the 16in aperture, clear of the vent
POST_PW    = 40.0                  # post width (u) -- lateral stability
POST_PAD   = 20.0                  # top pad length (v) -- COMPACT; bears on the faceplate underside
POST_FOOTL = 20.0                  # foot flange length (v) -- COMPACT; bolts to the base floor
POST_FELT  = 1.0                   # ASSEMBLED metal gap: a thicker (2-3 mm) felt/foam cap on the
                                   # pad compresses into this ~1 mm when the lid seats -> preloaded,
                                   # firm, rattle-free contact without jacking the lid.
POST_TILT  = SLOPE_ANGLE           # pad tilt (deg) so it beds FLUSH on the sloped faceplate underside
POST_BOLT_DU = 12.0                # M4 foot bolts at +/- this in u
# The shell is soft 1050 aluminium, but the posts are made in STEEL 1.6 mm: ~3x stiffer
# (E 200 vs 69 GPa), tougher, and only ~+60 g for the pair -- rigidity where it costs no
# weight (issue #292). Felt cap isolates the steel pad from the soft-Al faceplate.
POST_T     = 1.6                   # post sheet thickness (cold-rolled steel), NOT the shell's 2.0 Al
# foot + pad both extend FORWARD of the web (a C, all in the clear strip in front of the
# aperture); nothing sits under the display.
# web height: foot rests ON the base bottom plate (top at z=T, not z=0), pad ~POST_FELT
# below the faceplate underside. The formula (floor plate T + foot POST_T + felt gap +
# a ~1.5 mm faceplate seating drift below lid_top_z's bare slope) was calibrated against
# "Segno console (populated)" (the MANUFACTURING source of truth) at POST_V=158, giving
# web 40.9 mm -> foot on the floor, flush pad, 1.01 mm felt gap, no base interference.
# POST_V has since moved twice: to 137 (post pulled forward, issue #296) and then to
# 146.5 (Cherub slope-corrected slots, issue #360; web now ~38.3 mm) -- NOT re-checked
# against that doc at this position; re-verify there before fabrication.
POST_FACEDRIFT = 1.5
POST_H     = lid_top_z(POST_V) - T - POST_T - POST_FELT - POST_FACEDRIFT
_POST_VP   = POST_V * math.cos(math.radians(SLOPE_ANGLE))   # projected web depth on the flat base
_POST_FOOT_VP = _POST_VP - POST_FOOTL/2.0                   # foot-bolt depth (forward of the web)

def faceplate_holes():
    """All faceplate features. Pedal slots have NO mounting holes (the pedals
    stand on internal welded platforms). u=player L->R, v=front->rear."""
    cuts, engr = [], []
    # --- 10 pedal slots (two rows); a status LED pill above EVERY pedal --------
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
            vpos = v_lbl + (len(lines)-1-k)*(SILK_H*0.95)   # tight 2-line stack (issue #366)
            if len(lines) > 1:                         # multiline (REC/PLAY) -> left-aligned
                engr.append({"u": left_x, "v": vpos, "h": SILK_H, "s": ln, "wf": wf, "halign": "left"})
            else:                                      # single line -> centred on the pedal
                engr.append({"u": u, "v": vpos, "h": SILK_H, "s": ln, "wf": wf, "halign": "center"})
    # --- LED diffuser slots: ONE small pill window per indicator pedal, on the
    #     old status-LED centre-line (a single-LED WS2812B board under each,
    #     VHB-taped to the faceplate underside; white-PLA pill diffuser set into
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
    # --- encoder + diffused ring: on the OLD row-2 centre line (ENC_V -- it does
    #     NOT follow CLEAR/BANK rearward, see the PEDAL_ROW2_V note), and on
    #     COL_U -- the SAME vertical centre-line as the 7" screen (pedal 1/2 gap) -
    enc_v = ENC_V
    enc_u = COL_U                        # shared left-column centre-line (7" screen + ring)
    cuts.append({"kind": "ring",   "u": enc_u, "v": enc_v, "od": RING_OD, "id": RING_ID, "ref": "RING"})
    cuts.append({"kind": "circle", "u": enc_u, "v": enc_v, "d": D_ENC, "ref": "ENCODER"})
    # NOTE: no LEDs flank the encoder -- like the reference, the ring stands alone.
    # Power state shows on the rear power button.
    # The lid bolts to the body through its DOWN-TURNED SKIRT FLANGES (front lip +
    # sides + rear), NOT through this top face -- those screw holes live on the
    # flanges, added in dxf_faceplate / the render. So nothing more on the top here.
    # NOTE: the faceplate is reinforced by base-anchored SUPPORT POSTS (issue #292)
    # that bear on the underside -- they add NO holes here, keeping the top face clean.
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
    _text(msp, -pw/2+4, ph/2+6, 6, f"Segno REAR I/O PANEL ({variant})  2.0mm  x1  {label}  PROVISIONAL", "NOTE")
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

    # 2b. support posts (issue #292): bear on the panel JUST in front of the 16in
    # aperture (v<178), under the aperture width, tall enough to reach the underside.
    _aperture_edge_v = SCREEN_TOP_V - BIG_H
    assert POST_V < _aperture_edge_v, \
        f"POST_V {POST_V:.0f} not in front of the aperture edge ({_aperture_edge_v:.0f})"
    assert POST_H > 10.0, f"POST height {POST_H:.1f} mm too short at v={POST_V:.0f}"
    s16 = byref["SCREEN_16IN"]
    for u in POST_U:
        assert s16["u"] <= u <= s16["u"] + s16["w"], \
            f"post u={u:.0f} not under the 16in aperture ({s16['u']:.0f}..{s16['u']+s16['w']:.0f})"
    # COMPACT post sits in the band between the front pedals and the 15.6in BODY, and in the
    # TRACK LED-slot GAPS (in u) so the pad also clears the slots.
    assert POST_V - POST_PAD > PEDAL_ROW1_V + FSW_SLOT_D/2.0, \
        f"POST pad reaches back over the front pedals (v{POST_V-POST_PAD:.0f} vs {PEDAL_ROW1_V+FSW_SLOT_D/2:.0f})"
    body_front = SCREEN_TOP_V - BIG_BEZEL[1]   # 15.6in body extends forward to here
    assert POST_V < body_front, \
        f"POST web v={POST_V:.0f} not clear of the 15.6in body front (v={body_front:.0f})"
    # posts in the LED-slot gaps: no TRACK LED slot overlaps a post's pad (u +/- POST_PW/2)
    led = [_bbox(c) for c in cuts if c.get("ref","").endswith("_LEDSLOT")]
    for u in POST_U:
        for lb in led:
            assert not (lb[0] < u+POST_PW/2 and u-POST_PW/2 < lb[2]), \
                f"POST at u={u:.0f} overlaps an LED slot (u {lb[0]:.0f}..{lb[2]:.0f}) -- move to a gap"
    # post feet on the base must clear the intake vent (forward of the web)
    vent_bb = [_bbox(c) for c in _bottom_vents_local(W-2*T, D-2*T) if c.get("kind") == "rect"]
    vu0 = min(b[0] for b in vent_bb); vu1 = max(b[2] for b in vent_bb)
    vv0 = min(b[1] for b in vent_bb); vv1 = max(b[3] for b in vent_bb)
    for u in POST_U:
        for du in (-POST_BOLT_DU, POST_BOLT_DU):
            assert not (vu0 <= u+du <= vu1 and vv0-3 <= _POST_FOOT_VP <= vv1+3), \
                f"POST foot ({u+du:.0f},{_POST_FOOT_VP:.0f}) collides with the intake vent"

    # 3. platform head-room for BOTH rows: top pad flush+proud at each depth
    for v in (PEDAL_ROW1_V, PEDAL_ROW2_V):
        ph = platform_h(v)
        assert ph > T + 2.0, f"PLATFORM_HEADROOM: platform {ph:.1f} mm too low at v={v:.0f}"
        proud = ph + PEDAL_H - lid_top_z(v)        # how far the pedal stands proud
        assert -8.0 <= proud <= PEDAL_H, f"PLATFORM_HEADROOM: pedal proud {proud:.1f} mm at v={v:.0f}"
        # heat-set pilots need >= 3mm even in the LOW front pedestal (M3 x 3 shorts)
        pil = min(INSERT_DEPTH, (ph - T - 1.0) / 2.0)
        assert pil >= 3.0, f"PLATFORM_INSERTS: pilot depth {pil:.1f} mm < 3 at v={v:.0f} -- deck too shallow"
        # pocket floor must keep a solid web above the toe-side pilot bores
        assert (ph - T) - POCKET_DEPTH - pil >= 2.0, \
            f"PLATFORM_POCKET: web {(ph-T)-POCKET_DEPTH-pil:.1f} mm under the pocket at v={v:.0f}"

    # 3b. Cherub side-screw bosses pass UNDER the faceplate beside the slot: the
    # boss top must clear the underside where the sheet is solid. Pedal mounts
    # toe-forward, so its back edge sits at v + PEDAL_D/2 and the boss axis at
    # PEDAL_SCREW_BACK forward of it.
    for v in (PEDAL_ROW1_V, PEDAL_ROW2_V):
        v_screw = v + PEDAL_D / 2.0 - PEDAL_SCREW_BACK
        boss_top = platform_h(v) + PEDAL_PAD_T + PEDAL_SCREW_Z + PEDAL_SCREW_BOSS_D / 2.0
        # REAL clearance: bare-frame underside + the doc-calibrated seating drift
        # (the flush-at-rim seating (#373) eats the old margin; the bare frame
        # alone under-reports by face_drift and would false-fail row 2).
        clr = lid_under_z(v_screw) + face_drift(v_screw) - boss_top
        # flush-at-rim seating (#373) eats the old margin: real clearance is now
        # ~1.0 row 1 / ~0.95 row 2 (doc-probed). Static parts, no relative motion.
        assert clr >= 0.8, f"SCREW_BOSS: only {clr:.1f} mm under the faceplate at v={v_screw:.0f}"

    # 3c. the front gap absorbed the deeper Cherub slot; keep it usable
    assert FRONT_GAP >= 40.0, f"FRONT_GAP: {FRONT_GAP:.1f} mm < 40 -- pedals crowd the screen block"

    # 3d. light-baffle tub: pedal drops in, bosses ride the channels, walls stay
    # hidden behind the slot line, and the footprint clears neighbours + posts
    assert SKIRT_IN_W - PEDAL_W >= 2.0, "SKIRT: tub opening pinches the case"
    assert SKIRT_BOSS_CH_HALF >= PEDAL_SCREW_SPAN/2 + 0.5, "SKIRT: boss channel too shallow"
    assert SKIRT_BOSS_CH_W >= PEDAL_SCREW_BOSS_D + 2.0, "SKIRT: boss channel too narrow"
    assert SKIRT_IN_W - FSW_SLOT_W >= 2*SKIRT_SETBACK - 1e-9, "SKIRT: wall proud of the slot line (u)"
    assert 2*SKIRT_BOSS_CH_HALF < SKIRT_OUT_W, "SKIRT: boss channel exits the footprint"
    row1 = sorted(u for _, u, v in PEDALS if v == PEDAL_ROW1_V)
    pitch = min(b - a for a, b in zip(row1, row1[1:]))
    assert pitch - SKIRT_OUT_W >= 4.0, f"SKIRT: outer {SKIRT_OUT_W:.1f} vs pitch {pitch:.1f}"
    skirt_rear = PEDAL_ROW1_V + SKIRT_OUT_D / 2.0
    assert POST_V - POST_PAD - skirt_rear >= 0.8, \
        f"SKIRT: row-1 skirt rear v{skirt_rear:.1f} hits the post pad (front v{POST_V-POST_PAD:.1f})"

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
# board (the V1 segno_pedal_main) mounts there on M3 standoffs (>= STANDOFF_H for
# airflow). 16" screen above is shallow -> clears it.
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

# External 5V buck: eleUniverse 8-36V -> 5V 10A 50W IP67 potted brick (Amazon
# B0GGHN97TK; envelope 63.8 x 57.7 x 22.1 incl. mounting ears, 116 g, passive
# aluminium shell) — the add-on that makes 5V for the Pi + screens (the
# in-production board is untouched). Screws FLAT to the floor of the rear
# airflow bay by its two end ears (no standoffs), long axis along u.
# (Replaces the Pololu D24V90F5 — too expensive / hard to source.)
BUCK_BODY = (63.8, 57.7, 22.1)
BUCK_EAR_SPACING = 56.0       # ear hole centres along the long axis — PROVISIONAL
                              # until the unit arrives; drill to the real part
def buck_mount():
    bd = D - 2*T
    return (REAR_WIN_U + 125.0, bd - 60.0, BUCK_EAR_SPACING)

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
    # MASK is annotation, never cut: rings around the features the powder coater
    # has to keep bare (PEM threads, the earth stud's bonding land). Excluded from
    # every area/extents pass the same way NOTE/ENGRAVE are.
    doc.layers.add("MASK", color=1)
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
    # (dxf_overlay / segno_overlay). Keeps the metal a plain cut+bend+powder part (cheap).
    for u in FRONT_SCREW_U:
        _circle(msp, ox + u, ffl/2.0, D_M4)                                # front lip -> front wall (horizontal)
    for u in (PW*0.18, PW*0.5, PW*0.82):
        _circle(msp, ox + u, SEAM_M4_V, D_M4)                             # rear lap -> transition (concentric with the flange PEM row)
    _text(msp, 10, yr1+8, 8, f"Segno LID  2.0mm  x1  top plate + front lip + rear lap (= {180-(SLOPE_ANGLE+TRANS_ANGLE):.0f}deg); rests on the base side walls; no top screws; legends on printed OVERLAY (see segno_overlay); FOLD with the DRAWN side as the OUTSIDE face (canonical mirror: encoder lands on the player's LEFT)", "NOTE")
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
    _text(msp, 10, FP_V + 8, 8, "Segno TOP OVERLAY  printed adhesive (polycarbonate/vinyl); BLACK field + WHITE legend; die-cut apertures; bonded to the faceplate (no silkscreen on metal)", "NOTE")
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
    # The 4 vertical corners join via internal L-brackets (segno_corner_bracket), pop-riveted
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
    bkx, bky, bsp = buck_mount()                   # external 5V buck: 2 ear holes, flat mount
    for dx in (-bsp/2, bsp/2):
        _circle(msp, bkx+dx, bky, D_M4)
    _text(msp, bkx - bsp/2, bky + BUCK_BODY[1]/2 + 4, 5,
          "BUCK 5V (eleUniverse 8-36V>5V 10A IP67; ear pitch PROVISIONAL)", "NOTE")
    for x in (45, BW-45):
        for y in (45, BD-45):
            _circle(msp, x, y, D_FOOT)
    _emit(msp, platform_foot_holes())              # M3 holes for the 10 pedal-platform feet
    for u in POST_U:                               # 2 base-anchored support-post feet (issue #292)
        for du in (-POST_BOLT_DU, POST_BOLT_DU):   # foot forward of the web, clear of vent + display
            _circle(msp, u+du, _POST_FOOT_VP, D_M4)
    _text(msp, POST_U[0]-24, _POST_FOOT_VP + 8, 5,
          "SUPPORT POST feet x2 (M4; issue #292)", "NOTE")

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
        _circle(msp, BW*f, BD + SEAM_PEM_V, MASK_PEM_D, "MASK")        # keep the M4 thread bare
    for c in io:                                                       # bonding land: paint is an
        if c.get("ref") == "EARTH_STUD":                               # insulator, so the ring
            _circle(msp, c["u"], c["v"], MASK_GND_D, "MASK")           # terminal needs bare metal
    _text(msp, 8, BD+Hr+Ht+22, 7,
          "MASK (rojo / no pintar): 3x rosca PEM M4 en la transicion + "
          "zona de masa alrededor del perno M6 (ambas caras)", "MASK")

    _text(msp, 8, BD+Hr+Ht+10, 9,
          f"Segno BASE  2.0mm  x1  bottom + front/rear/sides fold up (bend ded {bdd:.2f}); WELD-FREE: rivet the 4 corners via L-brackets; rear 2nd fold = transition (flange FULL width, seats on the relieved side-wall tops); FOLD with the DRAWN side as the INSIDE face (canonical mirror: encoder lands on the player's LEFT)",
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
    _text(msp, 0, ht+6, 6, f"Segno CORNER BRACKET ({tag})  2.0mm  x2  weld-free corner join; rivet to both walls", "NOTE")
    doc.saveas(path); return {}

def platform_foot_u(sw):
    """The two x-fractions of the foot-flange screws, as offsets from the shelf centre."""
    return (-sw*0.25, sw*0.25)

def platform_foot_holes():
    """M3 clearance holes in the bottom plate for the 10 printed platforms: bolts
    pass UP through the floor into the heat-set inserts in each pedestal's
    underside (4 per platform), projected from each pedal onto the flat bottom."""
    cs = math.cos(math.radians(SLOPE_ANGLE))
    sw = SKIRT_OUT_W; sd = SKIRT_OUT_D; ff = PLATFORM_FOOT
    out = []
    for _label, u, v in PEDALS:
        vb = v * cs                                # pedal depth projected onto the flat bottom
        for d in platform_foot_u(sw):
            out.append({"kind": "circle", "u": u+d, "v": vb - sd/2 + ff/2, "d": D_M3, "ref": "PLAT_SCR"})
            out.append({"kind": "circle", "u": u+d, "v": vb + sd/2 - ff/2, "d": D_M3, "ref": "PLAT_SCR"})
    return out

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
        _circle(msp, x, -bf/2.0, MASK_PEM_D, "MASK")   # keep the M4 thread bare
        _circle(msp, x, bh/2.0, D_M4)
    _text(msp, 5, bh+6, 6, "Segno SCREEN BRACKET  2.0mm  x4 (16in) + x4 (7in)", "NOTE")
    _text(msp, 5, bh+14, 5, "MASK (rojo / no pintar): 2x rosca PEM M4", "MASK")
    doc.saveas(path); return {}

def dxf_post(path):
    """Base-anchored faceplate support post (issue #292), x2: a folded C -- foot
    (bolts to the base floor, M4 x2) + vertical web + top pad, foot and pad both
    forward of the web (all in the clear strip in front of the 16in aperture, nothing
    under the display). A felt cap on the pad bears on the faceplate underside,
    propping the one zone the perimeter folds do not reach. Load runs to the base, not
    the lid, so nothing shows on the top face and the lid still lifts off. The
    pad->web fold is 90 + POST_TILT deg so the pad beds FLUSH on the sloped underside;
    the foot->web fold is 90. Bend deduction PROVISIONAL (nominal segments)."""
    doc = _doc(); msp = doc.modelspace()
    pw, pad, web, foot = POST_PW, POST_PAD, POST_H, POST_FOOTL
    Wd = pad + web + foot
    _poly(msp, [(0, 0), (pw, 0), (pw, Wd), (0, Wd)], "CUT")
    _poly(msp, [(0, pad), (pw, pad)], "BEND", closed=False)           # pad -> web (fold 90 + tilt)
    _poly(msp, [(0, pad+web), (pw, pad+web)], "BEND", closed=False)   # web -> foot (fold 90)
    for du in (-POST_BOLT_DU, POST_BOLT_DU):                          # 2 M4 in the foot
        _circle(msp, pw/2.0 + du, pad + web + foot/2.0, D_M4)
    _text(msp, 5, Wd+6, 9,
          f"Segno FACEPLATE SUPPORT POST  {POST_T:.1f}mm COLD-ROLLED STEEL (not the Al shell)  x2  "
          f"C-fold (pad {pad:.0f} / web {web:.0f} / foot {foot:.0f} mm); pad fold {90+POST_TILT:.1f}deg "
          f"(beds flush on the {POST_TILT:.1f}deg slope), foot fold 90deg; foot bolts to the base floor "
          f"(M4 x2), felt cap on the pad; deduction PROVISIONAL", "NOTE")
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

def _platform_printed(cq, ph, v_c, standalone=True, baffle_t=None):
    """3D-printed pedal pedestal: solid deck + perimeter wall, hollowed below
    (tall MID parts) with boss columns at the insert stations. M3 heat-set
    inserts press in from BELOW at the base PLAT_SCR pattern; the deck top gets
    a shallow LOCATING POCKET for the Cherub's bottom anti-slip pad (the WTB-006
    has no base screws -- side screws only; retention PROVISIONAL), and a
    perimeter light-baffle SKIRT rises from the deck to SKIRT_GAP under the
    sloped faceplate (top cut at SLOPE_ANGLE; v_c = the pedal's slot centre in
    faceplate v, needed to height the skirt). Print BLACK. Origin: pedal
    centre, z=0 at the BASE PLATE TOP; height ph - T puts the deck at the
    pedal standing plane. Assembly frame: X = depth (v), Y = width (u); the
    pedal mounts TOE-FORWARD (back/cable end at +X)."""
    sw = SKIRT_OUT_W
    sd = SKIRT_OUT_D
    # A grown baffle ring takes the BODY with it. Sizing the ring alone left it
    # standing 0.75 mm proud of the pedestal face all round -- a lip, both a
    # down-facing ledge and simply wrong to look at (#539). Resolved here so
    # body, ring, notch and relief all read the same number.
    ring_od = sd if baffle_t is None else max(sd, SKIRT_IN_D + 2*baffle_t)
    sd = ring_od
    h = ph - T
    # cap the pilot depth in the LOW front pedestal (keeps a solid mid web and
    # clears the pad pocket above) and fit SHORT inserts (M3 x 3) instead of 5.7s
    pil = min(INSERT_DEPTH, (h - 1.0) / 2.0)
    body = cq.Workplane("XY").box(sd, sw, h, centered=(True, True, False))
    cav_h = h - PLAT_DECK
    foot_x = (-(sd/2 - PLATFORM_FOOT/2), sd/2 - PLATFORM_FOOT/2)
    # `standalone` = this pedestal is its own printed part, bolted to the base
    # plate from below. It then prints deck-down, so the weight-saving cavity
    # opens upward and costs nothing, and the base-insert pilots are reachable.
    # Built INTO the mini tray neither holds: the tray prints floor-down, which
    # turns the cavity into a 17,000 mm2 ceiling over a sealed void (nothing can
    # bridge it, and any support the slicer drops in is trapped forever), and
    # the pilots end up buried against the tray floor. Solid instead, and let
    # INFILL do the hollowing (#539).
    if standalone and cav_h > 2.0:
        body = body.cut(cq.Workplane("XY").box(
            sd - 2*PLAT_WALL, sw - 2*PLAT_WALL, cav_h, centered=(True, True, False)))
        for dx in foot_x:                      # boss columns for the base inserts
            for dy in platform_foot_u(sw):
                body = body.union(cq.Workplane("XY").cylinder(
                    cav_h, 6.0, centered=(True, True, False)).translate((dx, dy, 0)))
    if standalone:
        for dx in foot_x:                      # base inserts, from below
            for dy in platform_foot_u(sw):
                body = body.cut(cq.Workplane("XY").cylinder(
                    pil, INSERT_PILOT_D/2,
                    centered=(True, True, False)).translate((dx, dy, 0)))
    # bottom-pad locating pocket, from above. The pad is inset from the case
    # back edge, so its centre sits forward (toe-ward, -X) of the pedal centre:
    # pad centre from back = INSET + PAD_D/2; pedal centre from back = PEDAL_D/2.
    pocket_dx = (PEDAL_PAD_BACK_INSET + PEDAL_PAD_D/2.0) - PEDAL_D/2.0   # +X = rearward
    body = body.cut(cq.Workplane("XY").box(
        PEDAL_PAD_D + POCKET_CLR, PEDAL_PAD_W + POCKET_CLR, POCKET_DEPTH,
        centered=(True, True, False)).translate((-pocket_dx, 0, h - POCKET_DEPTH)))
    # light-baffle skirt: perimeter ring above the deck, top following the
    # sloped faceplate underside at SKIRT_GAP. Local +X = rearward = up-slope.
    # The ring's DEPTH walls are only (SKIRT_OUT_D - SKIRT_IN_D)/2 = 0.85 mm --
    # two beads, free-standing, ~28 mm tall. The inner face cannot move (it is
    # already only SKIRT_SETBACK behind the slot cut line), so a caller that
    # wants a printable baffle grows the ring OUTWARD instead; the 0.75 mm
    # ledge that leaves on the pedestal face is a trivial overhang. (#539)
    ring = (cq.Workplane("XY").box(ring_od, sw, 60.0, centered=(True, True, False))
            .cut(cq.Workplane("XY").box(SKIRT_IN_D, SKIRT_IN_W, 60.0,
                                        centered=(True, True, False)))
            .translate((0, 0, h)))
    drift = SKIRT_DRIFT_ROW1 if v_c < 150.0 else SKIRT_DRIFT_ROW2
    zc = lid_top_z(v_c) + drift - 2*T - SKIRT_GAP   # tub-top plane at x=0, local z (z0 = base top)
    cutter = (cq.Workplane("XY").box(400.0, 400.0, 200.0, centered=(True, True, False))
              .rotate((0, 0, 0), (0, 1, 0), -SLOPE_ANGLE)
              .translate((0, 0, zc)))
    ring = ring.cut(cutter)
    # boss drop-in channels: full-height vertical slots in BOTH side walls at the
    # screw axis, from the inner face out past the boss tip
    for side in (-1, 1):
        y0 = side * (SKIRT_IN_W/2 - 1.0)
        y1 = side * SKIRT_BOSS_CH_HALF
        ring = ring.cut(cq.Workplane("XY").box(
            SKIRT_BOSS_CH_W, abs(y1 - y0), 60.0,
            centered=(True, False, False)).translate(
                (SKIRT_BOSS_CH_X, min(y0, y1), h)))
    # cable notch: full-height slot centred in the REAR wall (+X = cable end).
    # Referenced to the RING's outer face, not to sd -- when baffle_t grows the
    # ring outward, a notch positioned off sd stops short and seals the slot
    # the pedal's cable leaves through (#539). The asserts below say so.
    NOTCH_L = 4.0
    notch_c = ring_od/2.0 - 1.5
    assert notch_c + NOTCH_L/2.0 >= ring_od/2.0 + 0.2, \
        "SKIRT: cable notch stops short of the ring's outer face -- slot sealed"
    assert notch_c - NOTCH_L/2.0 <= SKIRT_IN_D/2.0 - 0.2, \
        "SKIRT: cable notch does not reach the ring bore -- slot blind"
    ring = ring.cut(cq.Workplane("XY").box(
        NOTCH_L, SKIRT_NOTCH_W, 60.0,
        centered=(True, True, False)).translate((notch_c, 0, h)))
    body = body.union(ring)
    # PERIMETER RELIEF (#373): the tub footprint overhangs the slot opening
    # (1.25 mm front/rear, ~5.2 mm per side), so those strips lie UNDER the
    # faceplate (and under the down-turned front lip on row 1). With the
    # flush-raise the DECK BOX itself reaches that zone, so shave everything in
    # the perimeter region (outside the opening footprint) with the SAME
    # sloped plane the skirt cut uses -- which already sits ~0.3 under the
    # REAL plate (drift-calibrated per row). Deck inside the opening keeps
    # full height; the pedal (76.35 x 109.87) never sits on the shaved strips.
    opening_d = FSW_SLOT_D * math.cos(math.radians(SLOPE_ANGLE))
    ring_region = (cq.Workplane("XY").box(ring_od, sw, 200.0,
                                          centered=(True, True, False))
                   .cut(cq.Workplane("XY").box(opening_d, FSW_SLOT_W, 200.0,
                                               centered=(True, True, False))))
    body = body.cut(ring_region.intersect(cutter))
    return body

def build_platform_steps():
    """Printed platform pedestals: FRONT x8 + MID x2 (STEP + STL for slicing)."""
    import cadquery as cq
    outp = []
    for tag, v in (("front", PEDAL_ROW1_V), ("mid", PEDAL_ROW2_V)):
        body = _platform_printed(cq, platform_h(v), v)
        base = os.path.join(OUT, f"segno_platform_{tag}")
        cq.exporters.export(body.val(), base + ".step")
        cq.exporters.export(body, base + ".stl", tolerance=0.05)
        outp.append(base + ".step")
    return outp

def build_mini_console():
    """Fully 3D-printable STANDALONE MINI CONSOLE (issue #362; evolved from the
    #360 fit-test): 2 Cherub WTB-006 pedals (TRACK3/TRACK4 geometry, verbatim
    console constants -- so it doubles as the metal-order fit test) in a
    closed, openable wedge enclosure with a Pro Micro bay -- a working
    2-switch USB desk unit.
      TRAY -- floor + four REAL walls (tops follow the faceplate underside,
      row-1 drift incl.), both pedestal TUBS integrated (pocket, boss
      channels, cable notches facing the rear board bay), a Pro Micro POCKET
      boss against the rear wall with a USB cutout through it, and two rear
      screw BOSSES (M3 heat-set, vertical) the lid closes onto.
      LID  -- prints FLAT: the faceplate section (2 pedal slots + 2 LED
      pills), four registration tabs, two rear M3 through-holes. Open/close =
      two screws; the tabs + slope keep it located.

    PRINTABILITY (#539 -- the first tray warped at the sides). This is a
    199 x 156 mm flat print, which survives only if it is anchored over its
    whole footprint. The first rev stood on four 14 x 14 feet, so it gripped
    the bed over 2.5% of what it spanned and the entire floor started 2 mm up
    in the air: every mm of contraction pulled on four pads and the free edges
    curled. So: no printed feet (rubber ones stick into shallow recesses), the
    floor is its own bed contact, and it is 3.2 mm of PRINTED floor rather than
    the 2.0 mm aluminium sheet gauge it used to borrow. Walls run into the
    pedestal tubs instead of standing free beside them, the plan corners are
    radiused, and the wall/floor junction carries a gusset.
    Frame: X = u - MINI_U0, Y = FLAT (projected) v, Z = world z."""
    import cadquery as cq
    cs = math.cos(math.radians(SLOPE_ANGLE))
    tn = math.tan(math.radians(SLOPE_ANGLE))
    PEDS = [_row1_u(6), _row1_u(7)]  # the TRACK3/TRACK4 pair, pitch preserved
    V1S = 160.0                      # depth on-slope (pedals + pills + board bay)
    D = V1S * cs
    # PRINTED wall/floor gauges -- deliberately NOT T (that is sheet metal)
    FLOOR_T  = 3.2      # 16 layers at 0.2: enough section to resist curl
    WALL_T   = 3.2
    CORNER_R = 6.0      # plan corner radius: square corners peel first
    BOT_CHAM = 0.6      # bottom edge: kills elephant foot and the lifting knife edge
    GUSSET   = 2.5      # 45deg ramp along the wall/floor junction
    FOOT_D, FOOT_REC = 12.0, 0.5      # stick-on rubber feet, located by a groove
    FOOT_RING_W = 1.2                 # groove width (a solid recess would be a
                                      # 12 mm flat ceiling -> slicer adds support)
    MINI_BAFFLE_T = 1.6               # 4 beads on the tub's light-baffle ring
    ZLIFT = FLOOR_T - T               # everything above the floor rises with it
    # SYMMETRY (v2). The width used to be derived from the RIGHT tub alone and
    # the origin was a hardcoded U0=625.3 carried over from the big console, so
    # the pedal pair sat 1.74 mm right of the tray's centreline: 11.38 mm of
    # margin one side, 7.90 the other, on a face you look at. Size the tray from
    # the tub SPAN instead and put the origin where the pair lands centred --
    # then BOTH side walls overlap their tub by WALL_OVER and neither side needs
    # a filler strip. 3.48 mm narrower, and the strip that caused two of the
    # earlier lid clashes stops existing.
    WALL_OVER = 0.5                              # wall into tub, so the two fuse
    tub_span = (PEDS[1] - PEDS[0]) + SKIRT_OUT_W
    Wt = tub_span + 2.0*(WALL_T - WALL_OVER)
    U0 = (PEDS[0] + PEDS[1])/2.0 - Wt/2.0        # centres the pair, by construction
    C0 = (lid_top_z(PEDAL_ROW1_V) + SKIRT_DRIFT_ROW1 - T) - tn * (PEDAL_ROW1_V * cs) + ZLIFT
    # under-base lid anchors: triangle clamp, nothing on top. The screws lean
    # REARWARD going down (they follow the lid normal), so each bottom exit
    # lands ~(pillar-top z)*tan(slope) behind the pillar -- the rear pair
    # therefore sits at y=140 in the side strips (x 8.5 / 190.4, clear of the
    # diffuser flanges and the board bay) so the exits stay in open floor
    # instead of breaking through the rear wall footprint.
    ANCHORS = ((8.5, 139.0), (Wt - 8.5, 139.0), (Wt/2.0, 20.0))
    BOARD_W, BOARD_D = 34.2, 18.8    # Pro Micro pocket (33 x 18 board + clearance)
    BOARD_XC = (PEDS[0] + PEDS[1])/2.0 - U0   # centred between the tubs

    def slope_cut(sol, z0):
        cutter = (cq.Workplane("XY").box(900.0, 900.0, 300.0, centered=(True, True, False))
                  .rotate((0, 0, 0), (1, 0, 0), SLOPE_ANGLE)
                  .translate((0, 0, z0)))
        return sol.cut(cutter)

    # --- tray -------------------------------------------------------------
    # ONE rounded-rect shell hollowed from above, not five unioned boxes: the
    # corners come out radiused (nothing for a peeling edge to start from) and
    # there are no coincident union faces for the slicer to trip over. The
    # cavity's own bottom edge is chamfered, so cutting it leaves a 45deg
    # gusset all the way round the wall/floor junction.
    shell = (cq.Workplane("XY").box(Wt, D, 80.0, centered=False)
             .edges("|Z").fillet(CORNER_R))
    shell = shell.faces("<Z").chamfer(BOT_CHAM)
    cav = (cq.Workplane("XY").box(Wt - 2*WALL_T, D - 2*WALL_T, 80.0, centered=False)
           .edges("|Z").fillet(max(0.6, CORNER_R - WALL_T)))
    cav = cav.faces("<Z").chamfer(GUSSET).translate((WALL_T, WALL_T, FLOOR_T))
    tray = slope_cut(shell, C0).cut(cav)
    # NO top-face fasteners (same language as the big console): the lid clamps
    # from BELOW. Anchor pillars stop LID_BOSS_H short of the wall-top plane;
    # the lid carries insert bosses that land on them, and M3 screws come up
    # through the floor along the LID NORMAL (12.5deg from vertical), heads
    # recessed in pockets that stay clear of the table on their own.
    LID_BOSS_H = 8.0   # boss deep enough that the insert pilot NEVER enters the
                       # 2mm plate (tilted pilot tip rim stays below it) -- the
                       # top face stays pristine
    ncs, nsn = math.cos(math.radians(SLOPE_ANGLE)), math.sin(math.radians(SLOPE_ANGLE))
    for (bx, byy) in ANCHORS:
        by = (D - WALL_T - 6.8) if byy is None else byy
        # VERTICAL screw (user call): the bore drops straight through pillar and
        # floor -- no drift, exit directly under the pillar, flat head seat.
        # The 12.5deg lives in the LID's insert pilot instead (pressed tilted).
        pillar = cq.Workplane("XY").box(10.0, 12.0, 60.0, centered=False)\
            .translate((bx - 5.0, by - 6.0, FLOOR_T))
        # vertical drop of the boss bottom = LID_BOSS_H / cos(slope), +0.2 so the
        # WALLS stay the seating datum and the screws preload across the gap
        pillar = slope_cut(pillar, C0 - (LID_BOSS_H / ncs + 0.2))
        tray = tray.union(pillar)
        # exit pocket sits concentric under the pillar: keep it whole in the floor
        exit_rim = by + 4.25
        assert exit_rim <= (D - WALL_T) - 0.8, \
            f"MINI_ANCHOR: exit pocket rim y{exit_rim:.1f} too close to the rear wall"
        bore = cq.Workplane("XY").circle(1.8).extrude(90.0).translate((bx, by, -5.0))
        # 8.5 head/driver pocket from below, seat 1.5 above the floor top: the
        # head ends up ~4.7 mm off the table, so nothing has to lift the case
        pocket = cq.Workplane("XY").circle(4.25).extrude(40.0)\
            .translate((bx, by, FLOOR_T + 1.5 - 40.0))
        tray = tray.cut(bore).cut(pocket)
    # FEET: not printed. Printed pads made the floor a 30,000 mm2 bridge over
    # 784 mm2 of bed contact -- the warp that killed the first tray (#539).
    # Stick-on rubber feet drop into these recesses instead, which a floor unit
    # wants anyway, and the floor itself is what grips the bed.
    # ...located by an engraved RING, not a solid recess. A recess is a flat
    # 12 mm ceiling 0.5 mm off the bed, which every slicer supports; the groove
    # only ever has to bridge its own 1.2 mm width.
    for (fx, fy) in ((15.0, 15.0), (Wt - 15.0, 15.0),
                     (30.0, D - 14.0), (Wt - 30.0, D - 14.0)):
        tray = tray.cut(cq.Workplane("XY")
                        .circle(FOOT_D/2.0).circle(FOOT_D/2.0 - FOOT_RING_W)
                        .extrude(FOOT_REC).translate((fx, fy, 0.0)))
    yc = PEDAL_ROW1_V * cs
    for u in PEDS:
        ped = (_platform_printed(cq, platform_h(PEDAL_ROW1_V), PEDAL_ROW1_V,
                                 standalone=False, baffle_t=MINI_BAFFLE_T)
               .rotate((0, 0, 0), (0, 0, 1), 90)
               .translate((u - U0, yc, FLOOR_T)))
        tray = tray.union(ped)
    # BRACING. The tall thin side walls have to lean on something, and the bare
    # floor between and behind the tubs is where the warp map peaked.
    tub_x = [(u - U0 - SKIRT_OUT_W/2.0, u - U0 + SKIRT_OUT_W/2.0) for u in PEDS]
    tub_od = max(SKIRT_OUT_D, SKIRT_IN_D + 2*MINI_BAFFLE_T)   # body AND ring
    tub_y = (yc - tub_od/2.0, yc + tub_od/2.0)
    gap_l = tub_x[0][0] - WALL_T           # left wall stood in a 3 mm canyon
    if gap_l > 0.05:                       # fill it: the wall becomes tub-braced
        # front end at the wall (kills the sliver the cavity's corner radius
        # leaves), rear end at the tub -- running it full depth put it under the
        # rear anchor bosses, which drop 8 mm below the lid plane (#539)
        tray = tray.union(slope_cut(cq.Workplane("XY").box(
            gap_l + 0.2, tub_y[1] - WALL_T, 80.0, centered=False)
            .translate((WALL_T, WALL_T, FLOOR_T)), C0))
    for ry in (35.0, 66.0, 108.0):         # ties the two tubs to each other
        # (clear of the centre anchor at y=20: its pillar spans y 14..26 and the
        # lid's boss drops onto the pillar TOP, not onto a rib)
        tray = tray.union(cq.Workplane("XY").box(
            tub_x[1][0] - tub_x[0][1] + 0.4, 5.0, 8.0, centered=False)
            .translate((tub_x[0][1] - 0.2, ry - 2.5, FLOOR_T)))
    for rx in (30.0, 70.0, Wt - 70.0, Wt - 30.0):  # stiffens the open rear bay
        # (kept off the Pro Micro boss's x 80.0..122.2: a rib landing just
        # beside it leaves a 0.8 mm slot the nozzle cannot resolve)
        tray = tray.union(cq.Workplane("XY").box(
            4.0, (D - WALL_T) - tub_y[1] + 0.4, 8.0, centered=False)
            .translate((rx - 2.0, tub_y[1] - 0.2, FLOOR_T)))
    # Pro Micro bay: raised boss against the rear wall, open-top pocket, and a
    # USB cutout through the rear wall (board slides in from above; the USB
    # lead + pocket friction retain it -- PROVISIONAL, fine for the mini)
    boss = cq.Workplane("XY").box(BOARD_W + 8.0, BOARD_D + 4.0, 4.0, centered=False)\
        .translate((BOARD_XC - BOARD_W/2.0 - 4.0, D - WALL_T - BOARD_D - 4.0, FLOOR_T))
    pocket = cq.Workplane("XY").box(BOARD_W, BOARD_D, 3.0, centered=False)\
        .translate((BOARD_XC - BOARD_W/2.0, D - WALL_T - BOARD_D, FLOOR_T + 1.8))
    tray = tray.union(boss).cut(pocket)
    # USB pass-through, with a 45deg GABLE over it. A plain rectangle leaves a
    # 12 mm flat ceiling inside the wall -- bridgeable, but slicers support it.
    usb_w, usb_h, usb_x0 = 12.0, 5.0, BOARD_XC - 6.0
    usb_y0, usb_z0 = D - WALL_T - 1.0, FLOOR_T + 2.6
    usb_t = WALL_T + 2.0
    usb = cq.Workplane("XY").box(usb_w, usb_t, usb_h, centered=False)\
        .translate((usb_x0, usb_y0, usb_z0))
    # 50 deg flanks (margin over the 45 deg self-supporting limit) narrowing to
    # a 4 mm flat -- the extruder never reaches more than 4 mm unsupported, and
    # the opening stays short instead of growing a full gable's worth of height
    roof_top, roof_a = 4.0, 50.0
    roof_rise = (usb_w - roof_top)/2.0 * math.tan(math.radians(roof_a))
    roof = (cq.Workplane("XZ")
            .polyline([(usb_x0, usb_z0 + usb_h),
                       (usb_x0 + usb_w, usb_z0 + usb_h),
                       (usb_x0 + (usb_w + roof_top)/2.0, usb_z0 + usb_h + roof_rise),
                       (usb_x0 + (usb_w - roof_top)/2.0, usb_z0 + usb_h + roof_rise)])
            .close().extrude(usb_t))
    bb = roof.val().BoundingBox()
    roof = roof.translate((0, usb_y0 - bb.ymin, 0))   # land it in the rear wall
    tray = tray.cut(usb).cut(roof)

    # --- lid (prints FLAT; seats on the wall tops at the real slope) ------
    # SAME plan corners as the tray. The shell went rounded when it stopped
    # being four unioned boxes; the lid stayed a rectangle, so its square
    # corners hung over the tray's R6 by ~1.8 mm diagonally at all four (#539).
    # Tilted, a circular fillet here projects to an ellipse 6.0 x 5.86 -- wholly
    # inside the tray's R6 circle, so it insets by <=0.14 mm and never proud.
    # ...and a perimeter that is VERTICAL once seated, exactly like the tray's.
    # A flat slab tilted 12.5 deg tilts its edge faces with it: the ends met the
    # tray's vertical walls at a 12.5 deg kink (0.43 mm proud at the front,
    # short at the rear) and the corner fillets became LEANING cylinders against
    # the tray's upright ones. Sides were always fine -- tilting about X leaves
    # their normals horizontal.
    #   So do not shape the lid in its own frame at all. Take the tray's own
    # vertical envelope, pull it back through the seating transform, and cut the
    # blank with it. Outline, ends and corners then match the tray by
    # construction rather than by three separate corrections that each need
    # their own trigonometry.
    V1S_EXT = V1S + T * tn                    # reach the rear face after trimming
    env_lid = (cq.Workplane("XY").box(Wt, D, 400.0, centered=False)
               .edges("|Z").fillet(CORNER_R)
               .translate((0, 0, -200.0 - C0))
               .rotate((0, 0, 0), (1, 0, 0), -SLOPE_ANGLE))
    lid = cq.Workplane("XY").box(Wt, V1S_EXT, T, centered=False).intersect(env_lid)
    for u in PEDS:
        x = u - U0
        lid = lid.cut(cq.Workplane("XY").box(FSW_SLOT_W, FSW_SLOT_D, 3*T, centered=(True, True, False))
                      .translate((x, PEDAL_ROW1_V, -T)))
        vc = PEDAL_ROW1_V + FSW_SLOT_D/2 + LED_GAP
        lid = lid.cut(cq.Workplane("XY").slot2D(LED_SLOT_W, LED_SLOT_H).extrude(3*T)
                      .translate((x, vc, -T)))
    # insert bosses on the UNDERSIDE over each anchor pillar: take the M3
    # heat-set inserts the under-base screws thread into. Nothing on top.
    sn = math.sin(math.radians(SLOPE_ANGLE))
    for (bx, byy) in ANCHORS:
        by = (D - WALL_T - 6.8) if byy is None else byy
        # pilot axis VERTICAL in the assembled (tilted) state -> drilled at
        # SLOPE_ANGLE in the flat print, leaning rearward (+y_l) going up.
        # Entry point on the boss bottom chosen so the assembled axis passes
        # through (bx, by): y_l = (by - LID_BOSS_H*sin)/cos.
        y_pl = (by - LID_BOSS_H * sn) / cs
        lid = lid.union(cq.Workplane("XY").box(10.0, 10.0, LID_BOSS_H, centered=False)
                        .translate((bx - 5.0, y_pl - 4.25, -LID_BOSS_H)))
        # start the cutter 2mm BELOW the boss face: a tilted cylinder starting
        # AT the face leaves its tilted base disc proud on the forward side --
        # a wedge half-covering the mouth (the user's "half-hole")
        lid = lid.cut(cq.Workplane("XY").circle(INSERT_PILOT_D/2.0)
                      .extrude(INSERT_DEPTH + 0.4 + 2.0)
                      .rotate((0, 0, 0), (1, 0, 0), -SLOPE_ANGLE)
                      .translate((bx, y_pl - 2.0*sn, -LID_BOSS_H - 2.0*cs)))
    # registration tabs (pure locators; the anchors do the clamping).
    # FRONT pair: shallow, inside the y<8.5 strip before the tub front walls.
    # FRONT pair: they live in the strip between the front wall and the tub, and
    # that strip is now 4.56 mm wide (the baffle ring took the tub face out to
    # y=7.76). A tab hangs BELOW the lid plane, and the lid is tilted, so its
    # bottom edge lands tan(slope) further REARWARD than its top -- 5 mm of tab
    # walked 1.08 mm into the tub. Sized against the swept envelope, not the
    # footprint, with the two asserts spelling the strip out.
    FT_D, FT_H = 2.8, 3.0
    ft_y = (WALL_T + 0.3) / cs
    assert ft_y * cs >= WALL_T + 0.25, \
        "MINI_TAB: front tab overhangs the front wall top"
    assert (ft_y + FT_D) * cs + FT_H * sn <= tub_y[0] - 0.4, \
        "MINI_TAB: front tab sweeps into the pedestal tub"
    for tx in (40.0, Wt - 40.0):
        lid = lid.union(cq.Workplane("XY").box(10.0, FT_D, FT_H, centered=False)
                        .translate((tx - 5.0, ft_y, -FT_H)))
    # centred on tx like the front pair -- these used to be placed by their
    # CORNER, so mirroring the x value put the second one 10 mm off station
    for tx in (65.0, Wt - 65.0):
        lid = lid.union(cq.Workplane("XY").box(10.0, 10.0, 5.0, centered=False)
                        .translate((tx - 5.0, (D - WALL_T)/cs - 12.0, -5.0)))

    # SYMMETRY GATE. This part shipped 1.74 mm off-centre through six rounds of
    # printability and fit checking, because every gate asked "does it build and
    # assemble" and none asked "is it right". Mirror each solid about its own
    # centreline and diff: anything left over is material that exists on one
    # side and not the other.
    for _nm, _sol in (("tray", tray), ("lid", lid)):
        _mir = _sol.mirror("YZ").translate((Wt, 0, 0))
        _odd = _sol.val().cut(_mir.val())
        _v = _odd.Volume()
        assert _v < 1.0, (
            f"MINI_SYM: {_nm} has {_v:.1f} mm3 on one side only -- "
            + "; ".join(f"{c.Volume():.1f}mm3 at x{c.BoundingBox().xmin:.0f} "
                        f"y{c.BoundingBox().ymin:.0f}"
                        for c in sorted(_odd.Solids(),
                                        key=lambda q: q.Volume(), reverse=True)[:4]))

    # ASSEMBLY GATE. Three separate clashes got into this part by moving tray
    # geometry without re-checking what the lid drops into it (#539): the left
    # filler under the rear anchor bosses, a centre rib under the middle one,
    # and the front tabs after the tub grew. Cheap to just ask.
    # the two pill diffusers ride in the lid, so they belong in the gate too:
    # the right one's flange passes the right anchor boss with 0.7 mm to spare
    lid_asm = lid
    for u in PEDS:
        vcp = PEDAL_ROW1_V + FSW_SLOT_D/2 + LED_GAP
        lid_asm = lid_asm.union(
            _diffuser_solid(cq, LED_INS_CLR_FDM).translate((u - U0, vcp, 0)))
    seated = lid_asm.rotate((0, 0, 0), (1, 0, 0), SLOPE_ANGLE).translate((0, 0, C0))
    # ...and the other half of "does it close": nothing of the lid may hang over
    # the tray's outer envelope. Overlap alone never showed this -- a lid can
    # clear every tray feature and still overhang the edge it is meant to seat
    # on. The ONE thing allowed past it is the lip a tilted slab always makes:
    # the top face sits T*sin(slope) forward of the bottom, a 0.43 mm reveal at
    # the front (and the same inset at the rear).
    env = (cq.Workplane("XY").box(Wt, D, 400.0, centered=False)
           .edges("|Z").fillet(CORNER_R).translate((0, 0, -100.0)))
    over = seated.cut(env).val()
    over_v = over.Volume()
    # the ends are trimmed vertical now, so NOTHING may hang past the tray --
    # the old allowance forgave a lip that no longer exists
    assert over_v <= 2.0, (
        f"MINI_FIT: {over_v:.1f} mm3 of lid hangs past the tray -- "
        + "; ".join(f"{c.Volume():.1f}mm3 at x{c.BoundingBox().xmin:.0f} "
                    f"y{c.BoundingBox().ymin:.0f}" for c in over.Solids()))

    clash = tray.val().intersect(seated.val())
    clash_v = clash.Volume() if clash is not None else 0.0
    assert clash_v < 0.5, (
        f"MINI_FIT: tray and lid overlap by {clash_v:.1f} mm3 -- "
        + "; ".join(f"{c.Volume():.1f}mm3 near "
                    f"x{c.BoundingBox().xmin:.0f} y{c.BoundingBox().ymin:.0f} "
                    f"z{c.BoundingBox().zmin:.0f}" for c in clash.Solids()))

    # EVERY per-part file ships in PRINT orientation -- STEP and STL alike.
    # Shipping the STL flipped and the STEP in the assembly frame was a trap:
    # slicers import STEP, and the lid sliced from its assembly frame stands on
    # the tips of seven bosses with the whole 12,400 mm2 faceplate floating
    # 8 mm up (#539). The assembled relationship lives in ONE file instead,
    # which is more use than two parts that happen to share a frame.
    lid_print = lid.rotate((0, 0, 0), (1, 0, 0), 180)
    bb = lid_print.val().BoundingBox()
    lid_print = lid_print.translate((0, -bb.ymin, -bb.zmin))

    outp = []
    for tag, sol in (("tray", tray), ("lid", lid_print)):
        base = os.path.join(OUT, f"segno_mini_console_{tag}")
        cq.exporters.export(sol.val(), base + ".step")
        cq.exporters.export(sol, base + ".stl", tolerance=0.05)
        bb = sol.val().BoundingBox()
        print(f"Mini console {tag}: {base}.step/.stl  footprint "
              f"{bb.xmax-bb.xmin:.1f} x {bb.ymax-bb.ymin:.1f} x {bb.zmax-bb.zmin:.1f} mm"
              f"  (as printed: lay it down exactly as the file sits)")
        outp.append(base + ".step")

    # ...and the assembly, lid seated on the wall tops at the real slope: a
    # point (x, y_l, 0) on the lid maps to z = C0 + y_l*sin(slope), which is
    # the wall-top plane z = C0 + tan(slope)*y at y = y_l*cos(slope).
    asm = os.path.join(OUT, "segno_mini_console_assembly.step")
    cq.exporters.export(
        cq.Compound.makeCompound([tray.val(), seated.val()]), asm)
    print(f"Mini console assembly (CAD reference, NOT for slicing): {asm}")
    # Screw schedule. NOT one length: the anchors sit at different heights up
    # the wedge, so the rear pair spans ~26 mm more air than the front one.
    # Nothing else states this, and it is not guessable from the model.
    print("Mini console screws (M3, up through the floor into the lid inserts):")
    for (bx, byy) in ANCHORS:
        by = (D - WALL_T - 6.8) if byy is None else byy
        need = ((C0 + tn*by) - LID_BOSS_H/ncs) - (FLOOR_T + 1.5) + 5.0
        print(f"  ({bx:6.1f},{by:5.1f})  {need:5.1f} mm engaged "
              f"-> M3 x {5*round((need + 3)/5):.0f}, plus 3x M3 heat-set inserts")
    outp.append(asm)
    return outp

def _diffuser_solid(cq, clr):
    """The pill diffuser insert itself, at a given slot clearance."""
    lens_l = LED_SLOT_W - clr
    lens_w = LED_SLOT_H - clr
    lens_h = T + LED_INS_PROUD
    fl_l = LED_SLOT_W + 2 * LED_INS_FLANGE
    fl_w = LED_SLOT_H + 2 * LED_INS_FLANGE
    lens = cq.Workplane("XY").slot2D(lens_l, lens_w).extrude(lens_h)
    lens = lens.edges(">Z").chamfer(0.3)             # soft glow edge on the proud lip
    ins = lens.union(cq.Workplane("XY").slot2D(fl_l, fl_w).extrude(-LED_INS_FL_T))
    px, py, pd = LED_INS_POCKET                       # LED nest, back face
    # The nest is cut into the flange's BACK face, which is the face this part
    # prints on -- so a straight pocket puts a 6 mm flat ceiling four layers up.
    # Taper it at 45 deg instead: self-supporting, and the mouth still locates
    # the module (which the VHB over the flange retains anyway, not the depth).
    ins = ins.cut(cq.Workplane("XY").workplane(offset=-LED_INS_FL_T)
                  .rect(px, py)
                  .workplane(offset=pd).rect(px - 2*pd, py - 2*pd)
                  .loft())
    return ins


def build_diffuser_step():
    """LED pill diffuser INSERT (3D-print in WHITE PLA): a stadium lens that
    pushes into the faceplate slot FROM THE INSIDE until its shoulder flange
    seats on the panel's underside; the lens stands LED_INS_PROUD above the
    outer skin. The single-LED module (hardware/led_strip/ puck or an
    off-the-shelf WS2812B breakout) nests in a shallow pocket on the back and is
    VHB-taped over the flange, which also retains the insert.

    Two builds, identical except for slot clearance. x10 for the big console's
    CUT-SHEET faceplate, and x2 for the mini console, whose lid is PRINTED --
    same nominal 60 x 6 pill, but a printed slot needs a printed part's
    clearance to enter it."""
    import cadquery as cq
    out = []
    for tag, clr in (("segno_led_diffuser", LED_INS_CLR),
                     ("segno_mini_console_diffuser", LED_INS_CLR_FDM)):
        ins = _diffuser_solid(cq, clr)
        step = os.path.join(OUT, tag + ".step")
        cq.exporters.export(ins.val(), step)
        cq.exporters.export(ins.val(), os.path.join(OUT, tag + ".stl"))
        out.append(step)
    return out[0]


def build_ring_diffuser_step():
    """Encoder LED-ring diffuser INSERT (3D-print in WHITE PLA, x1):
    the annular sibling of segno_led_diffuser -- pushes into the faceplate's ring
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
    step = os.path.join(OUT, "segno_ring_diffuser.step")
    cq.exporters.export(ins.val(), step)
    cq.exporters.export(ins.val(), os.path.join(OUT, "segno_ring_diffuser.stl"))
    return step


def build_post_step():
    """Folded 3D of the base-anchored support post (issue #292, x2): foot flat on
    the floor, vertical web, top pad. X=u (width POST_PW), Y=v, Z=up."""
    import cadquery as cq
    pw, pad, web, foot, t = POST_PW, POST_PAD, POST_H, POST_FOOTL, POST_T
    # C-fold, foot + pad both FORWARD of the web. Local X=u(width), Y=v(depth), Z=up.
    # foot on the floor (Y 0..foot), web vertical at its back edge (Y=foot), pad hinged
    # at the web top and TILTED down-forward by POST_TILT to bed on the sloped underside.
    foot_p = cq.Workplane("XY").box(pw, foot, t, centered=False)                          # floor, Y 0..foot
    web_p  = cq.Workplane("XY").box(pw, t, web, centered=False).translate((0, foot, 0))   # vertical at Y=foot
    pad_p  = (cq.Workplane("XY").box(pw, pad, t, centered=False)
              .translate((0, foot - pad, web))                                            # flat at the top, forward
              .rotate((0, foot, web), (1, foot, web), -POST_TILT))                        # tilt to the slope (free end drops toward the FRONT to match)
    body = foot_p.union(web_p).union(pad_p)
    for du in (-POST_BOLT_DU, POST_BOLT_DU):                                              # M4 through the foot
        body = body.cut(cq.Workplane("XY").cylinder(
            2*t, D_M4/2.0, centered=(True, True, False)).translate((pw/2.0+du, foot/2.0, 0)))
    step = os.path.join(OUT, "segno_post.step")
    cq.exporters.export(body.val(), step)
    return step


def build_step(write_parts=True):
    import cadquery as cq
    os.makedirs(OUT, exist_ok=True)
    asm = cq.Assembly(name="Segno")
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
    # 10 printed platform pedestals under the pedal slots (X = pedal v, Y = pedal u);
    # mid-row (CLEAR/BANK) pedestals are taller because the lid is higher there.
    # Depth uses the SLOPE-PROJECTED station (v*cos) — the same projection
    # platform_foot_holes() drills the bottom plate with — so platform, floor
    # holes, and faceplate slot share one centre at every pedal position.
    _cs = math.cos(math.radians(SLOPE_ANGLE))
    for i, (label, u, v) in enumerate(PEDALS):
        plat = _platform_printed(cq, platform_h(v), v)
        addw(plat, f"platform_{i}", cq.Location(cq.Vector(v * _cs, u + T, T)))
    # representative segno_pedal_main board on standoffs, rear clear zone (visual stand-in;
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

    asm.save(os.path.join(OUT, "segno_assembly.step"))
    if write_parts:
        exp = cq.exporters.export
        # The base is ONE folded blank (see segno_base.dxf); the assembly STEP shows it
        # in 3D. Per-part STEPs: the removable lid (platforms export in
        # build_platform_steps as print files).
        exp(fp.val(), os.path.join(OUT, "segno_faceplate.step"))
    return os.path.join(OUT, "segno_assembly.step")

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
    bb = extents(e for e in msp if e.dxf.layer not in ("NOTE", "ENGRAVE", "ACRYLIC", "MASK"))
    if bb.has_data:
        x0, y0, _ = bb.extmin; x1, y1, _ = bb.extmax
        ax.annotate(f"{x1-x0:.1f}", ((x0+x1)/2, y0), ha="center", va="top", fontsize=11, color="#0a4")
        ax.annotate(f"{y1-y0:.1f}", (x0, (y0+y1)/2), ha="right", va="center", rotation=90, fontsize=11, color="#0a4")
    fig.text(0.04, 0.045, "Segno loopstation enclosure", fontsize=12, weight="bold")
    fig.text(0.04, 0.022,
             f"{title}   |   {material}   |   qty {qty}   |   units mm   |   "
             f"CUT(thru) · BEND(score) · WELD · VENT · ENGRAVE   |   bend R {RI:.1f}",
             fontsize=9, color="#333")
    fig.savefig(pdf_path, dpi=150); plt.close(fig)

# ===========================================================================
# PAINT QUOTE PACK  (issue #396)
# ---------------------------------------------------------------------------
# Powder coaters quote by m^2, so the one number they cannot work without is the
# painted surface -- and nobody can eyeball it off a flat pattern riddled with
# pedal slots and screen apertures. Everything here is DERIVED (areas from the
# CUT layer of the generated DXFs, sizes from the STEPs) so the sheet cannot go
# stale the way a hand-typed parts table does.
# ===========================================================================

AL_2MM = "Aluminio 2,0 mm"
ST_16  = "Acero laminado en frio 1,6 mm"

PAINT_FINISH = "Negro texturado mate (RAL 9005) - a confirmar contra cupon de muestra"

# dxf stem, label (ES), qty per unit, material, remark (ES).
# segno_overlay is a printed adhesive graphic, NOT metal -- it is never painted.
# segno_rear_panel_nopi is the ALTERNATIVE to _pi, so only one ships per unit.
# segno_screen_bracket is NOT here: the screens are bonded to the shell instead of
# clamped, so the brackets are never manufactured (they stay in DXF_PARTS as the
# fallback if bonding is abandoned).
PAINT_BOM = [
    ("segno_base",               "Cuerpo: piso + frente + laterales + trasera", 1, AL_2MM, "Pieza mas grande"),
    ("segno_faceplate",          "Tapa superior (faceplate)",                   1, AL_2MM, "Cara vista principal"),
    ("segno_rear_panel_pi",      "Panel trasero de I/O",                        1, AL_2MM, "Intercambiable"),
    ("segno_corner_bracket_rear","Angulo de esquina trasera",                   2, AL_2MM, "Interno"),
    ("segno_ring_disc",          "Disco central del aro de LEDs",               1, AL_2MM, "Interno"),
    ("segno_post",               "Poste de apoyo de la tapa",                   2, ST_16,  "ACERO: otro pretratamiento"),
]

def _poly_area(pts):
    a = 0.0
    for i in range(len(pts)):
        x0, y0 = pts[i][0], pts[i][1]
        x1, y1 = pts[(i + 1) % len(pts)][0], pts[(i + 1) % len(pts)][1]
        a += x0 * y1 - x1 * y0
    return abs(a) / 2.0

def _flat_area_mm2(dxf_path):
    """Net area of one face of the flat blank: the outer contour minus every
    aperture inside it. Cut-outs live on CUT and VENT; bulges are ignored, which
    costs a rounding error on fillets and nothing on the total."""
    import ezdxf
    msp = ezdxf.readfile(dxf_path).modelspace()
    areas = []
    for e in msp:
        if e.dxf.layer not in ("CUT", "VENT"):
            continue
        if e.dxftype() == "LWPOLYLINE":
            pts = [(p[0], p[1]) for p in e.get_points()]
            if len(pts) >= 3:
                areas.append(_poly_area(pts))
        elif e.dxftype() == "CIRCLE":
            areas.append(math.pi * e.dxf.radius ** 2)
    if not areas:
        return 0.0
    areas.sort(reverse=True)
    return max(0.0, areas[0] - sum(areas[1:]))

def _step_size(stem):
    """Folded bounding box (mm) of the modelled part, or None when there is no
    STEP for it. Sorted big-to-small: orientation in the file is not meaningful
    to a coater, only whether it fits the oven."""
    p = os.path.join(OUT, stem + ".step")
    if not os.path.exists(p):
        return None
    try:
        import cadquery as cq
        bb = cq.importers.importStep(p).val().BoundingBox()
        return tuple(sorted((bb.xlen, bb.ylen, bb.zlen), reverse=True))
    except Exception:  # pragma: no cover - STEP is optional for this sheet
        return None

def _paint_rows():
    rows, tot = [], {}
    for stem, label, qty, mat, remark in PAINT_BOM:
        dxf = os.path.join(OUT, stem + ".dxf")
        if not os.path.exists(dxf):
            continue
        one = _flat_area_mm2(dxf) / 1e6           # m^2, one face
        total = one * 2 * qty                      # both faces get coated
        size = _step_size(stem)
        rows.append({"label": label, "qty": qty, "mat": mat, "remark": remark,
                     "size": size, "one": one, "total": total})
        tot[mat] = tot.get(mat, 0.0) + total
    return rows, tot

def _draw_dxf(ax, dxf_path):
    """Render a flat pattern into an axes: cuts black, masking rings red."""
    import ezdxf
    from ezdxf.addons.drawing import RenderContext, Frontend
    from ezdxf.addons.drawing.matplotlib import MatplotlibBackend
    doc = ezdxf.readfile(dxf_path)
    doc.layers.get("CUT").rgb = (0, 0, 0)
    doc.layers.get("MASK").rgb = (220, 30, 30)
    ax.set_axis_off()
    Frontend(RenderContext(doc), MatplotlibBackend(ax)).draw_layout(doc.modelspace(), finalize=True)
    ax.set_aspect("equal")

def paint_quote_pdf(path):
    """Supplier-facing sheet (Spanish) for the powder-coating quote: parts table
    with painted area, then a masking page per part that has bare-metal zones."""
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.backends.backend_pdf import PdfPages
    rows, tot = _paint_rows()
    grand = sum(tot.values())
    mono = {"family": "monospace", "fontsize": 8.6}

    with PdfPages(path) as pdf:
        # ---- page 1: what has to be painted -------------------------------
        fig = plt.figure(figsize=(11.7, 8.3))   # A4 landscape
        fig.text(0.06, 0.995, "Segno - gabinete de controlador de audio", va="top",
                 fontsize=17, weight="bold")
        fig.text(0.06, 0.945, "Pedido de cotizacion: pintura en polvo termoconvertible",
                 va="top", fontsize=12, color="#444")
        y = 0.885
        for k, v in (("Envolvente del equipo armado",
                      f"{W:.0f} x {D:.0f} x {H_REAR:.0f} mm (lo que tiene que entrar al horno)"),
                     ("Material del cuerpo", "Aluminio 2,0 mm (aleacion 1050 o 5052 segun proveedor de corte)"),
                     ("Terminacion pedida", PAINT_FINISH),
                     ("Superficie total a pintar", f"{grand:.2f} m2 por equipo (ambas caras, sin contar cantos)"),
                     ("Cantidad", "1 unidad prototipo; despues por lotes")):
            fig.text(0.06, y, k, fontsize=9.5, color="#666")
            fig.text(0.30, y, v, fontsize=10.5, weight="bold")
            y -= 0.042

        hdr = (f"{'Pieza':<42}{'Cant':>5}{'Material':>31}{'Tamano (mm)':>20}"
               f"{'1 cara m2':>11}{'Total m2':>10}")
        y -= 0.030
        fig.text(0.06, y, hdr, **mono, weight="bold")
        y -= 0.012
        fig.text(0.06, y, "-" * len(hdr), **mono, color="#999")
        for r in rows:
            y -= 0.030
            sz = ("%.0f x %.0f x %.0f" % r["size"]) if r["size"] else "-"
            fig.text(0.06, y, f"{r['label']:<42}{r['qty']:>5}{r['mat']:>31}"
                              f"{sz:>20}{r['one']:>11.4f}{r['total']:>10.4f}", **mono)
            y -= 0.018
            fig.text(0.075, y, r["remark"], fontsize=7.6, color="#777", style="italic")
        y -= 0.030
        fig.text(0.06, y, "-" * len(hdr), **mono, color="#999")
        for mat, m2 in sorted(tot.items()):
            y -= 0.030
            fig.text(0.06, y, f"{'Subtotal ' + mat:<109}{m2:>10.4f}", **mono, weight="bold")
        y -= 0.032
        fig.text(0.06, y, f"{'TOTAL por equipo':<109}{grand:>10.4f}",
                 **mono, weight="bold", color="#0a4")

        notes = [
            "Notas para el aplicador:",
            "  1. La superficie es NETA: contorno exterior menos aperturas (ranuras de pedales, pantallas, ventilaciones). No incluye cantos.",
            "  2. Las piezas llegan cortadas y plegadas, sin ningun recubrimiento ni aceite protector. Pretratamiento para aluminio a cargo del aplicador.",
            "  3. Los postes son ACERO laminado en frio, no aluminio: van en linea aparte porque llevan otro pretratamiento.",
            "  4. Enmascarado: ver las paginas siguientes. Roscas PEM M4 tapadas y zona de masa alrededor del perno M6 sin pintura, en ambas caras.",
            "  5. Las aperturas de pantalla son ajustadas: la pelicula come decimas por cara. Si el espesor supera 100 um avisar antes de aplicar.",
            "  6. El aluminio es blando: colgar para pintar, no apoyar sobre las caras vistas.",
            "  7. La tapa figura con su tamano PLANO (850 x 407 x 2): plegada suma la pestana frontal de 12 mm y la solapa trasera.",
        ]
        # anchored, not flowed: the table above grows with the BOM and the notes
        # must not walk off the bottom of the sheet when it does
        y = 0.150
        for i, n in enumerate(notes):
            fig.text(0.06, y, n, fontsize=8.2, color="#222" if i == 0 else "#444",
                     weight="bold" if i == 0 else "normal")
            y -= 0.0195
        pdf.savefig(fig); plt.close(fig)

        # ---- masking / detail pages ---------------------------------------
        sheets = [
            ("segno_base", "CUERPO - plano de enmascarado",
             "Rojo = NO PINTAR. 3x rosca PEM M4 sobre la transicion (tapon de silicona) y "
             "zona de masa de 20 mm alrededor del perno M6, en ambas caras."),
            ("segno_faceplate", "TAPA SUPERIOR - aperturas criticas",
             "Sin enmascarado. Las dos aperturas grandes son de pantalla y quedan ajustadas "
             "contra el display: contemplar el espesor de pelicula."),
        ]
        for stem, title, note in sheets:
            dxf = os.path.join(OUT, stem + ".dxf")
            if not os.path.exists(dxf):
                continue
            fig = plt.figure(figsize=(11.7, 8.3))
            ax = fig.add_axes([0.04, 0.12, 0.92, 0.80])
            _draw_dxf(ax, dxf)
            fig.text(0.04, 0.965, title, fontsize=14, weight="bold")
            fig.text(0.04, 0.055, note, fontsize=9.5, color="#b00")
            fig.text(0.04, 0.025, "Segno loopstation enclosure   |   medidas en mm   |   "
                                  "patron plano (la pieza se entrega plegada)", fontsize=8, color="#555")
            pdf.savefig(fig); plt.close(fig)
    return path

# ===========================================================================
# REPORT
# ===========================================================================

def report():
    cuts, _ = faceplate_holes()
    L = []; P = L.append
    P("="*68)
    P("Segno sheet-metal enclosure — manufacturing package")
    P("="*68)
    P(f"Envelope        : {W:.0f} W x {D:.0f} D x {H_REAR:.0f} H mm (front lip {H_FRONT:.0f})")
    P(f"Top slope       : {SLOPE_ANGLE:.2f}deg, sloped length {L_SLOPE:.1f} mm")
    P(f"Material        : {T:.1f} mm 5052-H32 Al, bend R {RI:.1f}, K={KF}, BA90 {BA90:.2f}")
    P(f"Construction    : welded lower body + REMOVABLE TOP LID (faceplate carries")
    P(f"                  screens + encoder/ring PCB + LEDs; pedals stay on platforms)")
    P("-"*68)
    n1 = sum(1 for _, _, v in PEDALS if v == PEDAL_ROW1_V)
    P(f"Foot pedals     : {len(PEDALS)}x Cherub WTB-006 ({PEDAL_W:.1f}x{PEDAL_D:.1f}x{PEDAL_H:.1f}mm incl. pads, toe-forward)")
    P(f"  layout        : {n1} front row + {len(PEDALS)-n1} centre (CLEAR/BANK), LEDs aligned above")
    P(f"  slot          : {FSW_SLOT_W:.0f}(u) x {FSW_SLOT_D:.0f}(v) mm  [PROVISIONAL]")
    P(f"  platform H    : front {platform_h(PEDAL_ROW1_V):.1f} / mid {platform_h(PEDAL_ROW2_V):.1f} mm "
      f"(case top flush with the slot's upper rim, pad +{PEDAL_PAD_T:.1f} above, #373)  [PROVISIONAL]")
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
         f'Segno TOP FACEPLATE — player view · {W:.0f} x {D:.0f} x {H_REAR:.0f} mm · '
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
    e.append(f'<text x="{M}" y="{fy+18:.1f}" fill="#7c8aa3" font-size="10.5">10x Cherub WTB-006 pedals on printed pedestals (PROVISIONAL) · 10 indicator LED pills (one per pedal) + encoder ring · Pi+board mount on the rear bottom plate</text>')
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
        ph=platform_h(v); add(_platform_printed(cq,ph,v).val().moved(cq.Location(cq.Vector(v,u+T,T))), PLAT)
        add(cq.Workplane("XY").box(PEDAL_D,PEDAL_W,PEDAL_H,centered=(True,True,False)).translate((v,u+T,ph)).val(), PED)
        # pink/magenta bumper strip across the foot-plate (reference accent)
        add(cq.Workplane("XY").box(16,PEDAL_W-8,2,centered=(True,True,False)).translate((v-PEDAL_D*0.22,u+T,ph+PEDAL_H)).val(), STRIP)
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
    _text(msp, -RING_ID/2, RING_ID/2 + 6, 5, "Segno LED-RING CENTRE DISC  2.0mm  x1  (encoder clamps it)", "NOTE")
    doc.saveas(path); return {}

# ===========================================================================
# MAIN
# ===========================================================================

DXF_PARTS = [
    ("segno_faceplate",        dxf_faceplate),
    ("segno_overlay",          dxf_overlay),  # printed adhesive top-plate graphic (replaces silkscreen)
    ("segno_base",             dxf_base),     # bottom + front/rear/side walls, ONE folded blank
    ("segno_screen_bracket",   dxf_screen_bracket),
    ("segno_ring_disc",        dxf_ring_disc),                        # LED-ring centre disc
    ("segno_corner_bracket_rear",  lambda p: dxf_corner_bracket(p, CORNER_HT, CORNER_ZR_WALL, CORNER_ZR_SIDE, "REAR x2")),
    ("segno_rear_panel_pi",    lambda p: dxf_rear_panel(p, "pi")),    # swappable rear I/O
    ("segno_rear_panel_nopi",  lambda p: dxf_rear_panel(p, "nopi")),
    ("segno_post",             dxf_post),  # base-anchored faceplate support post x2 (issue #292)
]
NO_PDF = set()   # every sheet part ships with a PDF drawing

def build_quote_packages():
    """Refresh the manufacturer zips from the CURRENT outputs so they can never
    go stale (a hand-built segno_sheetmetal.zip once shipped three-week-old
    flats). Three packs: laser/bend sheet metal, reference STEPs, 3D prints."""
    import zipfile
    zips = []

    def pack(zname, names, exts):
        zp = os.path.join(OUT, zname)
        with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
            for n in names:
                for ext in exts:
                    p = os.path.join(OUT, n + ext)
                    if os.path.exists(p):
                        z.write(p, n + ext)
        zips.append(zp)

    sheet = [n for n, _ in DXF_PARTS]
    pack("segno_sheetmetal.zip", sheet, (".dxf", ".pdf"))
    pack("segno_sheetmetal_step.zip",
         ["segno_assembly", "segno_base", "segno_faceplate", "segno_screen_bracket",
          "segno_corner_bracket_rear", "segno_rear_panel_pi", "segno_ring_disc",
          "segno_post"],
         (".step",))
    pack("segno_3dprint.zip",
         ["segno_platform_front", "segno_platform_mid",
          "segno_led_diffuser", "segno_ring_diffuser"],
         (".step", ".stl"))
    # Powder-coat quote pack: the Spanish sheet + every painted part's PDF.
    # Deliberately NO DXFs -- the coater cuts nothing, and a flat pattern only
    # invites confusion. Narrowed to the paint BOM -- not every DXF_PART.
    pack("segno_pintura.zip", ["segno_paint_quote"] + [s for s, *_ in PAINT_BOM], (".pdf",))
    return zips

def main(argv):
    print(report())
    print("\nGeometry assertions ...", end=" ")
    _check()
    print("ALL PASS")
    if "--report" in argv:
        return
    os.makedirs(OUT, exist_ok=True)
    layout_svg(os.path.join(HERE, "segno_panel_layout.svg"))
    print("\nAnnotated layout: segno_panel_layout.svg")
    print("DXF flat patterns:")
    for name, fn in DXF_PARTS:
        dxf = os.path.join(OUT, name + ".dxf"); fn(dxf)
        print("  out/" + name + ".dxf")
        if "--no-pdf" not in argv and name not in NO_PDF:
            try:
                dxf_to_pdf(dxf, os.path.join(OUT, name + ".pdf"),
                           title=name.replace("segno_", "").replace("_", " ").upper())
                print("  out/" + name + ".pdf")
            except Exception as e:  # pragma: no cover
                print(f"    (pdf skipped: {e})")
    if "--no-pdf" not in argv:
        try:
            paint_quote_pdf(os.path.join(OUT, "segno_paint_quote.pdf"))
            print("\nPaint quote sheet: out/segno_paint_quote.pdf")
        except Exception as e:  # pragma: no cover
            print(f"\n(paint quote skipped: {e})")
    if "--no-step" not in argv:
        try:
            build_diffuser_step()
            print("\nLED diffuser insert (3D print, WHITE PLA, flange-down):")
            print("  big console x10: out/segno_led_diffuser.step (+ .stl)")
            print("  mini console x2: out/segno_mini_console_diffuser.step (+ .stl)"
                  "  -- same pill, printed-lid clearance")
            r = build_ring_diffuser_step()
            print("Ring diffuser insert (3D print, x1): out/" + os.path.basename(r) + " (+ .stl)")
            s = build_post_step()
            print("Faceplate support post (base-anchored, x2): out/" + os.path.basename(s))
            for pp in build_platform_steps():
                print("Printed platform: out/" + os.path.basename(pp) + " (+ .stl)")
            build_mini_console()
            p = build_step()
            print("\n3D STEP:\n  " + os.path.relpath(p, HERE) + " (+ per-part .step)")
        except Exception as e:  # pragma: no cover
            print(f"\n(STEP skipped: {e})")
    for z in build_quote_packages():
        print("Quote package: out/" + os.path.basename(z))
    if "--render" in argv:
        try:
            r = render_png(os.path.join(OUT, "segno_render.png"))
            print("\nShaded render:\n  out/segno_render.png")
        except Exception as e:  # pragma: no cover
            print(f"\n(render skipped: {e})")

if __name__ == "__main__":
    main(set(sys.argv[1:]))
