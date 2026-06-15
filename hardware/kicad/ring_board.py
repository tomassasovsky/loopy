"""SKiDL generator for the Loopy pedal RING board (12-LED ring + encoder).

Run (from hardware/kicad/):
    set KICAD8_SYMBOL_DIR=C:\\Program Files\\KiCad\\10.0\\share\\kicad\\symbols
    python ring_board.py
"""

from skidl import (
    Part, Net, generate_netlist, ERC, POWER, set_default_tool, KICAD8,
    lib_search_paths,
)

set_default_tool(KICAD8)
lib_search_paths[KICAD8].append(
    r"C:\Program Files\KiCad\10.0\share\kicad\symbols"
)


def R(value):
    return Part("Device", "R", value=value,
                footprint="Resistor_SMD:R_0603_1608Metric")


def C(value, fp="Capacitor_SMD:C_0603_1608Metric"):
    return Part("Device", "C", value=value, footprint=fp)


gnd = Net("GND")
v5 = Net("+5V_LED")
ring_data = Net("RING_DATA")
encA = Net("ENC_A")
encB = Net("ENC_B")
encSW = Net("ENC_SW")

# 8-pin connector to the main board (mirrors main board J5):
#   1,2 = +5V_LED   3,4 = GND   5 = RING_DATA   6 = ENC_A   7 = ENC_B   8 = ENC_SW
j1 = Part("Connector_Generic", "Conn_01x08",
          footprint="Connector_JST:JST_XH_B8B-XH-A_1x08_P2.50mm_Vertical", ref="J1")
j1[1, 2] += v5
j1[3, 4] += gnd
j1[5] += ring_data
j1[6] += encA
j1[7] += encB
j1[8] += encSW

# bulk cap at the ring's power entry
C("1000uF", "Capacitor_SMD:CP_Elec_8x10")[1, 2] += v5, gnd

# EC11 rotary encoder with switch: A,B,C (common), S1,S2 (switch)
enc = Part("Device", "RotaryEncoder_Switch",
           footprint="Rotary_Encoder:RotaryEncoder_Alps_EC11E-Switch_Vertical_H20mm",
           ref="ENC1")
enc["A"] += encA
enc["B"] += encB
enc["C"] += gnd
enc["S1"] += encSW
enc["S2"] += gnd
# encoder RC filtering + pull-ups (encoders bounce)
R("10k")[1, 2] += v5, encA
R("10k")[1, 2] += v5, encB
C("100nF")[1, 2] += encA, gnd
C("100nF")[1, 2] += encB, gnd

# 12-LED WS2812B ring chain
prev = ring_data
for i in range(12):
    led = Part("LED", "WS2812B",
               footprint="LED_SMD:LED_WS2812B-2020_2.0x2.0mm", ref=f"D{i+1}")
    led["VDD"] += v5
    led["VSS"] += gnd
    led["DIN"] += prev
    nxt = Net(f"RING_D{i+1}")
    led["DOUT"] += nxt
    prev = nxt
    if i % 4 == 0:
        C("100nF")[1, 2] += v5, gnd

for _n in (gnd, v5):
    _n.drive = POWER

ERC()
generate_netlist()
