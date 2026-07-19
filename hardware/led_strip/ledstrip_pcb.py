"""loopy LED strip — parametric chainable WS2812B segment PCB.

Generates a **manufacturing package** for one 16 x 8 mm single-LED indicator
puck for the VAMP console: ONE board per indicator pedal (behind the
faceplate's small pill diffuser slot), 1x WS2812B 5050 addressable LED with
100nF decoupling, castellated half-hole pads on both 8 mm ends. Boards
daisy-chain pedal-to-pedal with three short wires (5V / data / GND) soldered
to the end pads — the castellations double as wire pads, and butting boards
end-to-end still works if a bar is ever wanted.

Electrical topology (one segment):

    left edge                                                    right edge
    [5V ]────────────── +5V rail, top long edge (F.Cu) ──────────────[5V ]
    [DI ]──D1─▶──D2─▶──D3─▶──D4──────────────────────────────────────[DO ]
    [GND]────────────── GND rail, bottom long edge (F.Cu) ───────────[GND]
                        + full GND pour on B.Cu

WHY the rails sit this way: the WS2812B PLCC4 pinout (datasheet, and the KiCad
footprint which cites it) is 1=VDD, 2=DOUT, 3=GND, 4=DIN with VDD/GND on the
package DIAGONAL (pin 1 top-left at 0 deg).  At rotation 0 that puts VDD
top-left / GND bottom-right / DIN top-right / DOUT bottom-left — so with +5V
along the top edge and GND along the bottom edge every LED reaches its rail
with a short straight stub, and the castellations read 5V / DATA / GND top to
bottom on BOTH ends (same order, so chaining is a straight butt joint).

WHY data hops on B.Cu: a bridging 100nF cap (rail to rail) next to each LED
blocks the whole 8 mm width on the top layer at its x position, so the data
chain dives to the bottom layer through a via pair per hop and cuts through
the GND pour. Short top stubs connect each via to its SMD pad.

Castellations: 1.6 mm plated pads, 0.8 mm drill, centred exactly ON the board
edge — JLCPCB's "castellated holes" option mills the edge through the hole
centres leaving half-holes. Pads carry the KiCad "castellated" property and
the board's copper-to-edge clearance is 0 so DRC understands the intent.

Everything is driven by pcbnew (KiCad 10) — run with KiCad's bundled python:

    /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 ledstrip_pcb.py

Outputs (./out): loopy_led_strip.kicad_pcb, gerbers/ + drill files, and
loopy_led_strip_gerbers.zip ready to upload to JLCPCB.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
BOARD_PATH = os.path.join(OUT, "loopy_led_strip.kicad_pcb")

KICAD_CLI = "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
KICAD_FP = "/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints"

# ===========================================================================
# PARAMETERS — edit here; everything downstream is derived (mm, KiCad y-down)
# ===========================================================================

N_LEDS = 1  # ONE LED per board: a small per-pedal indicator puck
LED_PITCH = 16.0  # board length per LED; also preserved if boards are butted
BOARD_L = N_LEDS * LED_PITCH  # 16.0 — the LED sits PITCH/2 from each edge
BOARD_W = 8.0
CORNER_R = 1.0  # Edge.Cuts corner radius
CY = BOARD_W / 2  # long-axis centreline: every LED centre sits on it

ORIGIN = (50.0, 50.0)  # board top-left corner on the KiCad sheet

LED_FP = ("LED_SMD", "LED_WS2812B_PLCC4_5.0x5.0mm_P3.2mm")
CAP_FP = ("Capacitor_SMD", "C_0603_1608Metric")

# Rails: 1.5 mm copper along both long edges (spec minimum). Centred 0.85 mm
# from the edge (span 0.1..1.6) so they keep 0.25 mm clearance to the LED pad
# rows at y 2.35/5.65 — needs edge clearance 0, which the castellations
# require anyway. The rails stop short of the rounded corners (RAIL_X0) so
# their copper never crosses the r=1 corner arcs; short diagonal connectors
# tie each rail end into its castellated pad.
RAIL_W = 1.5
RAIL_5V_Y = 0.85  # +5V rail centre (top long edge)
RAIL_GND_Y = BOARD_W - 0.85  # GND rail centre (bottom long edge)
RAIL_X0 = 1.8  # rail x start/stop (>= CORNER_R + end-cap radius, w/ margin)

# Castellated end pads: 5V / DATA / GND, top to bottom, both ends.
CAST_PITCH = 2.5  # y offsets -2.5 / 0 / +2.5 from the centreline
CAST_PAD = 1.6  # pad diameter (the milled half-hole width)
CAST_DRILL = 0.8

# Decoupling: one vertical 100nF bridging +5V rail -> GND rail, tucked on the
# LED's left. 4.2 mm keeps its courtyard clear of the LED's and its stubs
# clear of the LED pad columns (led_x - 2.45).
CAP_DX = -4.2

# Data chain plumbing: each hop leaves DOUT via a short top stub down to a
# via, crosses on B.Cu (through the GND pour), and pops up next to DIN.
# The two via rows are spread as far apart as the SMD pad rows allow (0.25 mm
# via-to-pad clearance) because each hop's diagonal passes the NEIGHBOURING
# LED's via 4.9 mm from the hop end — the wider the rows, the more clearance
# where it passes (checked in _check()).
VIA_D = 0.8
VIA_DRILL = 0.4
VIA_Y_DIN = 3.45  # via feeding a DIN pad (pad row y=2.35, via below it)
VIA_Y_DOUT = 4.55  # via draining a DOUT pad (pad row y=5.65, via above it)

TRACK_DATA = 0.4
TRACK_STUB = 0.6  # pad-to-rail power stubs
TRACK_CAP = 0.5  # cap-pad-to-rail stubs (cap pad is only 0.95 wide)

# GND rail -> B.Cu pour stitching vias: one per inter-LED gap, ON the rail;
# a 1-LED puck gets a single stitch beside the cap.
STITCH_XS = ([LED_PITCH * (i + 1) for i in range(N_LEDS - 1)]
             if N_LEDS >= 2 else [BOARD_L / 2.0 + 3.0])

SILK_H = 0.8  # min legible silk height (see pcb-layout skill)
SILK_T = 0.15

FromMM = pcbnew.FromMM


def P(x: float, y: float) -> pcbnew.VECTOR2I:
    """Board-local mm -> absolute sheet nanometres."""
    return pcbnew.VECTOR2I(FromMM(ORIGIN[0] + x), FromMM(ORIGIN[1] + y))


# ===========================================================================
# Geometry sanity checks — run before any output, in the spirit of the
# enclosure generator's assertion suite.
# ===========================================================================


def _check() -> None:
    # Chain-seam pitch: LED1 of the NEXT board lands PITCH/2 past the joint,
    # LED4 of THIS board is PITCH/2 before it -> exactly one LED_PITCH.
    first_led = LED_PITCH / 2
    last_led = BOARD_L - LED_PITCH / 2
    assert first_led + (BOARD_L - last_led) == LED_PITCH, "seam pitch broken"
    # Rails stay 1.5 mm+ and inside the board.
    assert RAIL_W >= 1.5
    assert RAIL_5V_Y - RAIL_W / 2 >= 0 and RAIL_GND_Y + RAIL_W / 2 <= BOARD_W
    # Rails keep 0.25 mm clearance to the LED data/power pad rows.
    assert (2.35 - 0.45) - (RAIL_5V_Y + RAIL_W / 2) >= 0.25
    assert (RAIL_GND_Y - RAIL_W / 2) - (5.65 + 0.45) >= 0.25
    # Rail end caps stay clear of the r=1 corner arcs.
    assert RAIL_X0 - RAIL_W / 2 >= CORNER_R
    # Castellations clear the corner radius arcs (pads at y 1.5 / 6.5).
    assert CY - CAST_PITCH - CAST_PAD / 2 > CORNER_R - 0.4
    # Vias keep >=0.25 mm to the LED pad rows (pad half-height 0.45).
    assert (VIA_Y_DIN - VIA_D / 2) - (2.35 + 0.45) >= 0.25
    assert (5.65 - 0.45) - (VIA_Y_DOUT + VIA_D / 2) >= 0.25
    # Each B.Cu hop diagonal passes the neighbouring LED's via 4.9 mm in from
    # the hop end; keep >=0.25 mm copper clearance there. (No hops on a 1-LED
    # puck -- the check only applies when LEDs chain on-board.)
    if N_LEDS >= 2:
        hop_dx = LED_PITCH + 4.9
        passing = (VIA_Y_DOUT - VIA_Y_DIN) * (1 - 4.9 / hop_dx)
        assert passing >= VIA_D / 2 + TRACK_DATA / 2 + 0.25, passing


# ===========================================================================
# Board construction
# ===========================================================================


def _add_net(board: pcbnew.BOARD, name: str) -> pcbnew.NETINFO_ITEM:
    net = pcbnew.NETINFO_ITEM(board, name)
    board.Add(net)
    return net


def _track(board, net, layer, width, x1, y1, x2, y2) -> None:
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(P(x1, y1))
    t.SetEnd(P(x2, y2))
    t.SetLayer(layer)
    t.SetWidth(FromMM(width))
    t.SetNet(net)
    board.Add(t)


def _via(board, net, x, y) -> None:
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(P(x, y))
    v.SetDrill(FromMM(VIA_DRILL))
    v.SetWidth(FromMM(VIA_D))
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    v.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    v.SetNet(net)
    board.Add(v)


def _silk_text(board, text, x, y, h=SILK_H, w=None) -> None:
    t = pcbnew.PCB_TEXT(board)
    t.SetText(text)
    t.SetPosition(P(x, y))
    t.SetLayer(pcbnew.F_SilkS)
    t.SetTextSize(pcbnew.VECTOR2I(FromMM(w if w else h), FromMM(h)))
    t.SetTextThickness(FromMM(SILK_T))
    board.Add(t)


def _silk_line(board, x1, y1, x2, y2, w=0.2) -> None:
    s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(P(x1, y1))
    s.SetEnd(P(x2, y2))
    s.SetLayer(pcbnew.F_SilkS)
    s.SetWidth(FromMM(w))
    board.Add(s)


def _outline(board) -> None:
    """80 x 8 rounded rect (r=1) on Edge.Cuts: 4 lines + 4 corner arcs."""
    r = CORNER_R
    lines = [
        (r, 0, BOARD_L - r, 0),  # top
        (BOARD_L, r, BOARD_L, BOARD_W - r),  # right
        (BOARD_L - r, BOARD_W, r, BOARD_W),  # bottom
        (0, BOARD_W - r, 0, r),  # left
    ]
    for x1, y1, x2, y2 in lines:
        s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_SEGMENT)
        s.SetStart(P(x1, y1))
        s.SetEnd(P(x2, y2))
        s.SetLayer(pcbnew.Edge_Cuts)
        s.SetWidth(FromMM(0.1))
        board.Add(s)
    k = r * (1 - 0.70710678)  # arc midpoint offset at 45 deg
    arcs = [  # start, mid, end (counter-clockwise around the board)
        ((0, r), (k, k), (r, 0)),  # top-left
        ((BOARD_L - r, 0), (BOARD_L - k, k), (BOARD_L, r)),  # top-right
        ((BOARD_L, BOARD_W - r), (BOARD_L - k, BOARD_W - k), (BOARD_L - r, BOARD_W)),
        ((r, BOARD_W), (k, BOARD_W - k), (0, BOARD_W - r)),  # bottom-left
    ]
    for start, mid, end in arcs:
        s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_ARC)
        s.SetArcGeometry(P(*start), P(*mid), P(*end))
        s.SetLayer(pcbnew.Edge_Cuts)
        s.SetWidth(FromMM(0.1))
        board.Add(s)


def _castellated_end(board, ref, x_edge, nets) -> None:
    """Three plated half-hole pads centred ON one 8 mm end.

    nets = (net_5v, net_data, net_gnd), placed top to bottom. JLC's
    castellated-holes option mills the edge through the hole centres.
    """
    fp = pcbnew.FOOTPRINT(board)
    fp.SetReference(ref)
    fp.Reference().SetVisible(False)
    fp.SetValue("castellated_edge")
    board.Add(fp)
    fp.SetPosition(P(x_edge, CY))
    for i, (net, dy) in enumerate(
        zip(nets, (-CAST_PITCH, 0.0, CAST_PITCH)), start=1
    ):
        pad = pcbnew.PAD(fp)
        pad.SetNumber(str(i))
        pad.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
        pad.SetShape(pcbnew.PAD_SHAPE_CIRCLE)
        pad.SetSize(pcbnew.VECTOR2I(FromMM(CAST_PAD), FromMM(CAST_PAD)))
        pad.SetDrillSize(pcbnew.VECTOR2I(FromMM(CAST_DRILL), FromMM(CAST_DRILL)))
        pad.SetLayerSet(pcbnew.PAD.PTHMask())
        pad.SetProperty(pcbnew.PAD_PROP_CASTELLATED)
        fp.Add(pad)
        pad.SetPosition(P(x_edge, CY + dy))
        pad.SetNet(net)


def _place_fp(board, lib, name, ref, x, y, rot_deg) -> pcbnew.FOOTPRINT:
    fp = pcbnew.FootprintLoad(os.path.join(KICAD_FP, lib + ".pretty"), name)
    if fp is None:
        raise SystemExit(f"footprint {lib}:{name} not found")
    fp.SetReference(ref)
    fp.Reference().SetVisible(False)  # keep the tiny board's silk readable
    # The WS2812B library footprint carries a silk "1" pin marker that lands
    # exactly where the decoupling cap sits — drop loose silk texts.
    for item in list(fp.GraphicalItems()):
        if isinstance(item, pcbnew.PCB_TEXT):
            fp.Remove(item)
    board.Add(fp)
    fp.SetPosition(P(x, y))
    fp.SetOrientationDegrees(rot_deg)
    return fp


def _pad_mm(fp, number) -> tuple:
    """A pad's absolute position back in board-local mm (post placement)."""
    p = fp.FindPadByNumber(str(number)).GetPosition()
    return (pcbnew.ToMM(p.x) - ORIGIN[0], pcbnew.ToMM(p.y) - ORIGIN[1])


def build() -> pcbnew.BOARD:
    _check()
    board = pcbnew.CreateEmptyBoard()
    bds = board.GetDesignSettings()
    bds.SetCopperLayerCount(2)
    bds.SetBoardThickness(FromMM(1.6))
    # Castellated pads and edge rails sit ON/at the outline by design.
    bds.m_CopperEdgeClearance = FromMM(0)

    net_5v = _add_net(board, "+5V")
    net_gnd = _add_net(board, "GND")
    # DIN -> LED1 -> ... -> LEDn -> DOUT (hop nets derived from N_LEDS)
    hop_names = ["D%d%d" % (i + 1, i + 2) for i in range(N_LEDS - 1)]
    data = [_add_net(board, n) for n in ["DIN"] + hop_names + ["DOUT"]]

    _outline(board)

    # --- rails first (the critical high-current nets, hand-routed wide) ----
    _track(board, net_5v, pcbnew.F_Cu, RAIL_W, RAIL_X0, RAIL_5V_Y,
           BOARD_L - RAIL_X0, RAIL_5V_Y)
    _track(board, net_gnd, pcbnew.F_Cu, RAIL_W, RAIL_X0, RAIL_GND_Y,
           BOARD_L - RAIL_X0, RAIL_GND_Y)
    # Rail-end connectors: a 0.8 mm diagonal from inside each castellated
    # power pad (centres at y 1.5/6.5) to the rail end. Started 0.5 mm inboard
    # so the track's round end cap never crosses the board edge.
    for x_pad, x_rail, sgn in ((0.5, RAIL_X0, 1), (BOARD_L - 0.5, BOARD_L - RAIL_X0, 1)):
        _track(board, net_5v, pcbnew.F_Cu, 0.8, x_pad, CY - CAST_PITCH,
               x_rail, RAIL_5V_Y)
        _track(board, net_gnd, pcbnew.F_Cu, 0.8, x_pad, CY + CAST_PITCH,
               x_rail, RAIL_GND_Y)

    # --- chain ends: castellations land INSIDE the rail copper bands -------
    _castellated_end(board, "J1", 0.0, (net_5v, data[0], net_gnd))
    _castellated_end(board, "J2", BOARD_L, (net_5v, data[-1], net_gnd))

    # --- LEDs + decoupling -------------------------------------------------
    for i in range(N_LEDS):
        x = LED_PITCH / 2 + i * LED_PITCH
        led = _place_fp(board, *LED_FP, f"D{i+1}", x, CY, 0)
        # WS2812B PLCC4: 1=VDD 2=DOUT 3=GND 4=DIN (footprint's cited datasheet)
        for num, net in ((1, net_5v), (2, data[i + 1]), (3, net_gnd), (4, data[i])):
            led.FindPadByNumber(str(num)).SetNet(net)
        vx, vy = _pad_mm(led, 1)  # VDD top-left -> straight up to +5V rail
        _track(board, net_5v, pcbnew.F_Cu, TRACK_STUB, vx, vy, vx, RAIL_5V_Y)
        gx, gy = _pad_mm(led, 3)  # GND bottom-right -> straight down to rail
        _track(board, net_gnd, pcbnew.F_Cu, TRACK_STUB, gx, gy, gx, RAIL_GND_Y)

        # 100nF bridging the rails right next to the LED it decouples. The
        # bridge is why data must dive to B.Cu (it blocks the top corridor).
        cap = _place_fp(board, *CAP_FP, f"C{i+1}", x + CAP_DX, CY, 90)
        pads = sorted(cap.Pads(), key=lambda p: p.GetPosition().y)
        pads[0].SetNet(net_5v)  # upper pad -> +5V rail above
        pads[1].SetNet(net_gnd)  # lower pad -> GND rail below
        for pad, rail_y, net in (
            (pads[0], RAIL_5V_Y, net_5v),
            (pads[1], RAIL_GND_Y, net_gnd),
        ):
            px = pcbnew.ToMM(pad.GetPosition().x) - ORIGIN[0]
            py = pcbnew.ToMM(pad.GetPosition().y) - ORIGIN[1]
            _track(board, net, pcbnew.F_Cu, TRACK_CAP, px, py, px, rail_y)

    # --- data chain: B.Cu hops between via pairs ---------------------------
    leds = [f for f in board.GetFootprints() if f.GetReference().startswith("D")]
    leds.sort(key=lambda f: f.GetPosition().x)

    def din_drop(led, net):
        """via below DIN (top-right pad), stub up into the pad."""
        x, y = _pad_mm(led, 4)
        _via(board, net, x, VIA_Y_DIN)
        _track(board, net, pcbnew.F_Cu, TRACK_DATA, x, VIA_Y_DIN, x, y)
        return x, VIA_Y_DIN

    def dout_drop(led, net):
        """via above DOUT (bottom-left pad), stub down into the pad."""
        x, y = _pad_mm(led, 2)
        _via(board, net, x, VIA_Y_DOUT)
        _track(board, net, pcbnew.F_Cu, TRACK_DATA, x, VIA_Y_DOUT, x, y)
        return x, VIA_Y_DOUT

    # DIN castellation (through-plated, so it joins B.Cu directly) -> LED1
    x1, y1 = din_drop(leds[0], data[0])
    _track(board, data[0], pcbnew.B_Cu, TRACK_DATA, 0, CY, x1, y1)
    # LEDn DOUT -> LED(n+1) DIN
    for i in range(N_LEDS - 1):
        net = data[i + 1]
        ox, oy = dout_drop(leds[i], net)
        ix, iy = din_drop(leds[i + 1], net)
        _track(board, net, pcbnew.B_Cu, TRACK_DATA, ox, oy, ix, iy)
    # last LED DOUT -> DOUT castellation
    ox, oy = dout_drop(leds[-1], data[-1])
    _track(board, data[-1], pcbnew.B_Cu, TRACK_DATA, ox, oy, BOARD_L, CY)

    # --- GND pour on B.Cu (continuous return plane) + rail stitching -------
    z = pcbnew.ZONE(board)
    z.SetLayer(pcbnew.B_Cu)
    z.SetNet(net_gnd)
    z.SetLocalClearance(FromMM(0.25))
    z.SetMinThickness(FromMM(0.25))
    o = z.Outline()
    o.NewOutline()
    for x, y in ((0, 0), (BOARD_L, 0), (BOARD_L, BOARD_W), (0, BOARD_W)):
        o.Append(FromMM(ORIGIN[0] + x), FromMM(ORIGIN[1] + y))
    board.Add(z)
    for sx in STITCH_XS:
        _via(board, net_gnd, sx, RAIL_GND_Y)

    # --- silkscreen --------------------------------------------------------
    # Title fits the 12 mm corridor between LED2's DIN column and C3's bridge
    # (slightly condensed glyphs: 0.6 wide x 0.8 tall).
    # Title in the first inter-LED gap, arrow in the second (both gap-centred
    # so they stay clear of LED and cap courtyards at any N/pitch). A 1-LED
    # puck has no gaps: the end-pad labels are the only silk that fits.
    if N_LEDS >= 2:
        _silk_text(board, "loopy LED strip v1", LED_PITCH, CY, w=0.6)
    if N_LEDS >= 3:
        ax = 2.0 * LED_PITCH
        _silk_line(board, ax - 4.0, CY, ax + 4.0, CY)
        _silk_line(board, ax + 2.5, CY - 0.8, ax + 4.0, CY)
        _silk_line(board, ax + 2.5, CY + 0.8, ax + 4.0, CY)
    # Castellation labels, both ends: 5V / DI|DO / GND top to bottom.
    lx = 1.8 if BOARD_L < 30 else 3.2   # end labels hug the pads on short pucks
    for x, dname in ((lx, "DI"), (BOARD_L - lx, "DO")):
        _silk_text(board, "5V", x, CY - CAST_PITCH, h=0.8, w=0.6)
        _silk_text(board, dname, x, CY, h=0.8, w=0.6)
        _silk_text(board, "GND", x, CY + CAST_PITCH, h=0.8, w=0.6)

    # NOTE: ZONE_FILLER segfaults in KiCad 10.0.4's standalone python on this
    # board, so the pour is filled after saving via
    # `kicad-cli pcb drc --refill-zones --save-board` (see export()).
    return board


# ===========================================================================
# Outputs: board file, gerbers + drill, zip for JLCPCB
# ===========================================================================


def export(board: pcbnew.BOARD) -> None:
    os.makedirs(OUT, exist_ok=True)
    pcbnew.SaveBoard(BOARD_PATH, board)
    print(f"wrote {BOARD_PATH}")

    # Fill the B.Cu GND pour + run DRC in one go (in-process ZONE_FILLER
    # segfaults; the CLI's filler is the same engine the GUI uses).
    drc_report = os.path.join(OUT, "drc.json")
    drc = subprocess.run(
        [
            KICAD_CLI, "pcb", "drc", "--refill-zones", "--save-board",
            "--severity-all", "--format", "json", "-o", drc_report, BOARD_PATH,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    print(drc.stdout.strip())

    gerber_dir = os.path.join(OUT, "gerbers")
    shutil.rmtree(gerber_dir, ignore_errors=True)
    os.makedirs(gerber_dir)
    subprocess.run(
        [
            KICAD_CLI, "pcb", "export", "gerbers",
            "--layers", "F.Cu,B.Cu,F.Mask,B.Mask,F.Silkscreen,B.Silkscreen,F.Paste,Edge.Cuts",
            "-o", gerber_dir + "/", BOARD_PATH,
        ],
        check=True,
    )
    subprocess.run(
        [
            KICAD_CLI, "pcb", "export", "drill",
            "--excellon-separate-th", "-o", gerber_dir + "/", BOARD_PATH,
        ],
        check=True,
    )
    zip_base = os.path.join(OUT, "loopy_led_strip_gerbers")
    shutil.make_archive(zip_base, "zip", gerber_dir)
    print(f"wrote {zip_base}.zip")


def main() -> None:
    board = build()
    export(board)


if __name__ == "__main__":
    sys.exit(main())
