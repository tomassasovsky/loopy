"""SKiDL generator for the Loopy pedal RING/ENCODER base board.

Hosts an off-the-shelf **16-LED WS2812 5050 NeoPixel ring module** (wired to a
4-pin header) plus the rotary encoder and the link to the main board. Everything
on this board is THROUGH-HOLE -- no SMD to hand-solder, and the LED ring is a
pre-assembled module, so there are no WS2812s on this PCB at all.

Run (from hardware/kicad/):
    python ring_board.py     # KICAD_SYMBOL_DIR may override the symbol path
"""
import os

from skidl import (
    Part, Net, generate_netlist, ERC, POWER, set_default_tool, KICAD8,
    lib_search_paths,
)

set_default_tool(KICAD8)

_SYMBOL_DIRS = [
    os.environ.get("KICAD_SYMBOL_DIR", ""),
    r"C:\Program Files\KiCad\10.0\share\kicad\symbols",
    r"C:\Program Files\KiCad\9.0\share\kicad\symbols",
    "/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols",
    "/Applications/KiCad.app/Contents/SharedSupport/symbols",
    "/usr/share/kicad/symbols",
]
for _d in _SYMBOL_DIRS:
    if _d and os.path.isdir(_d):
        lib_search_paths[KICAD8].append(_d)

# ---- THT footprint helpers -------------------------------------------------

def R(value):
    return Part("Device", "R", value=value,
                footprint="Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal")


def C(value, fp="Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"):
    return Part("Device", "C", value=value, footprint=fp)


# ---- nets ------------------------------------------------------------------

gnd = Net("GND")
v5 = Net("+5V_LED")
ring_data = Net("RING_DATA")     # data from main board -> module DIN
ring_dout = Net("RING_DOUT")     # module DOUT (spare; for chaining a 2nd ring)
encA = Net("ENC_A")
encB = Net("ENC_B")
encSW = Net("ENC_SW")

# ---- 8-pin link to the main board (mirrors main board J6 RING header) -------
#   1,2 = +5V_LED   3,4 = GND   5 = RING_DATA   6 = ENC_A   7 = ENC_B   8 = ENC_SW
j1 = Part("Connector_Generic", "Conn_01x08",
          footprint="Connector_JST:JST_XH_B8B-XH-A_1x08_P2.50mm_Vertical", ref="J1")
j1[1, 2] += v5
j1[3, 4] += gnd
j1[5] += ring_data
j1[6] += encA
j1[7] += encB
j1[8] += encSW

# ---- 4-pin header to the NeoPixel module (3 wires used: 5V/GND/DIN) ---------
#   1 = +5V_LED   2 = GND   3 = DIN (<- RING_DATA)   4 = DOUT (spare)
j2 = Part("Connector_Generic", "Conn_01x04",
          footprint="loopy:WirePads_1x04",   # flat FRONT solder pads (wires to module)
          ref="J2", value="NEOPIXEL")
j2[1] += v5
j2[2] += gnd
j2[3] += ring_data
j2[4] += ring_dout

# 4 distributed THT pads directly under the module's In/+5V/GND/Out pads (Adafruit
# JP1/JP3/JP4/JP2) so the ring can be pin-mounted instead of flying-wired (parallel
# to J2 -- same nets, either connection method works). The Out pin carries the
# spare DOUT net but is mainly there to solder down a 4th post for rigidity.
j3 = Part("Connector_Generic", "Conn_01x04",
          footprint="loopy:ModuleMountPads_4", ref="J3", value="RINGPINS")
j3[1] += ring_data   # DIN
j3[2] += v5          # +5V
j3[3] += gnd         # GND
j3[4] += ring_dout   # DOUT (spare; soldered for mechanical support)

# bulk cap at the module power entry (16 LEDs ~1 A) -- THT radial electrolytic
Part("Device", "C_Polarized", value="470uF",
     footprint="Capacitor_THT:CP_Radial_D8.0mm_P3.50mm")[1, 2] += v5, gnd

# ---- EC11 rotary encoder (A,B,C common, S1,S2 switch) ----------------------
enc = Part("Device", "RotaryEncoder_Switch",
           footprint="loopy:RotaryEncoder_EC11",   # vendored EC11 (LCSC C202365) + 3D model
           ref="ENC1")
enc["A"] += encA
enc["B"] += encB
enc["C"] += gnd
enc["S1"] += encSW
enc["S2"] += gnd
# pull-ups + RC de-bounce (encoders bounce). Powered from +5V_LED, so the encoder
# is live only in standalone/9V mode -- same as the LED ring.
R("10k")[1, 2] += v5, encA
R("10k")[1, 2] += v5, encB
C("100nF")[1, 2] += encA, gnd
C("100nF")[1, 2] += encB, gnd

for _n in (gnd, v5):
    _n.drive = POWER

ERC()
generate_netlist()
