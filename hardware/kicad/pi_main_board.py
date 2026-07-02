"""SKiDL generator for the Loopy **Pi main board** (standalone Raspberry Pi 4/5).

DIY / through-hole edition: every part is hand-solderable THT (TO-220 buck +
reverse-prot FET, DIP-20 buffer, axial resistors, disc/radial caps, leaded
diodes, 3mm LED).  The only SMD-ish parts are the connectors, which are all
through-hole anyway (GPIO socket, JST, barrel, pin headers).

The Raspberry Pi mounts via the 2x20 GPIO socket and runs the loopy audio engine
itself (audio I/O via a USB audio interface on the Pi).  This board carries
pedalboard power, the 10 footswitches, the EC11 encoder and the two WS2812
strips.  No MIDI / USB-device silicon -- the Pi reads the footswitches directly
over GPIO, and handles USB-MIDI controllers in software.

Reference designators are explicit so the layout script can cluster each part
functionally.  Symbol names/pins are for KiCad 10.

See ../loopy_pi_main_pcb_design.md.

Run (from hardware/kicad/):
    set KICAD8_SYMBOL_DIR=C:\\Program Files\\KiCad\\10.0\\share\\kicad\\symbols
    python pi_main_board.py
"""

from skidl import (
    Part, Net, generate_netlist, ERC, POWER,
    set_default_tool, KICAD8, lib_search_paths,
)

set_default_tool(KICAD8)
lib_search_paths[KICAD8].append(r"C:\Program Files\KiCad\10.0\share\kicad\symbols")

RES = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal"
CER = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"          # ceramic disc (100nF)
ELE = "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm"            # radial electrolytic

def R(value, ref):
    return Part("Device", "R", value=value, ref=ref, footprint=RES)

def C(value, ref):
    return Part("Device", "C", value=value, ref=ref, footprint=CER)

def CP(value, ref):
    return Part("Device", "C_Polarized", value=value, ref=ref, footprint=ELE)

# ---- nets ------------------------------------------------------------------

gnd = Net("GND")
v5 = Net("+5V")          # single buck rail: powers the Pi AND the LED buffers
v3v3 = Net("+3V3")       # OUTPUT from the Pi (pins 1/17); used on the I2C header
v9 = Net("+9V")          # after reverse-polarity protection
vin_raw = Net("VIN_RAW")  # barrel center pin (before the P-FET)
q1g = Net("Q1_GATE")
pgood = Net("PWR_GOOD")
ind_data = Net("IND_DATA")          # GPIO18 / PWM0 -> buffer
ind_data_out = Net("IND_DATA_OUT")  # buffer + 330R -> off-board strip
ind_buf = Net("IND_BUF")
ring_data = Net("RING_DATA")        # GPIO13 / PWM1 -> buffer
ring_data_out = Net("RING_DATA_OUT")  # buffer + 330R -> cable
ring_buf = Net("RING_BUF")
sda = Net("I2C_SDA")
scl = Net("I2C_SCL")
pwrbtn = Net("PWR_BTN")
encA = Net("ENC_A")
encB = Net("ENC_B")
encSW = Net("ENC_SW")

# ---- J1: Raspberry Pi 4/5 40-pin GPIO header (ribbon-connected) -------------

# 2x20 male boxed IDC header on the TOP side. A 40-pin ribbon cable links it to
# the Pi's GPIO header, so this board sits separately instead of stacking on the
# Pi (avoids the Pi's tall USB/Ethernet jacks fouling the board). Pinout is 1:1
# with the Pi via a straight-through ribbon.
pi = Part("Connector", "Raspberry_Pi_4",
          footprint="Connector_IDC:IDC-Header_2x20_P2.54mm_Vertical",
          ref="J1", value="RPi_GPIO_Ribbon")
pi[2, 4] += v5
pi[1, 17] += v3v3
pi[6, 9, 14, 20, 25, 30, 34, 39] += gnd
pi[3] += sda
pi[5] += scl
pi[12] += ind_data       # GPIO18 PWM0
pi[33] += ring_data      # GPIO13 PWM1
pi[29] += encA           # GPIO5
pi[31] += encB           # GPIO6
pi[36] += encSW          # GPIO16
pi[35] += pwrbtn         # GPIO19
# GPIO14/15 (pins 8/10) and SPI0 (19/21/23/24/26) left free.

# footswitches -> Pi GPIO (active-low, internal pull-ups) + 100nF debounce each
fsw = [("RECPLAY", 7), ("STOP", 11), ("UNDO", 13), ("MODE", 15), ("TRACK1", 16),
       ("TRACK2", 18), ("TRACK3", 22), ("TRACK4", 32), ("CLEAR", 38), ("BANK", 40)]
for i, (name, pin) in enumerate(fsw):
    n = Net("SW_" + name)
    pi[pin] += n
    jp = Part("Connector_Generic", "Conn_01x02",
              footprint="Connector_JST:JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical",
              ref="J%d" % (3 + i), value="FSW_" + name)
    jp[1] += n
    jp[2] += gnd
    C("100nF", "C%d" % (12 + i))[1, 2] += n, gnd   # debounce cap (C12..C21)

# ---- Power: 9V barrel -> reverse-prot P-FET -> 5V buck module -> +5V --------

j2 = Part("Connector", "Barrel_Jack",
          footprint="Connector_BarrelJack:BarrelJack_Horizontal", ref="J2")
j2[1] += vin_raw        # center (positive)
j2[2] += gnd            # sleeve
# High-side reverse-polarity P-FET: IRF9540N (TO-220, -100V/-23A, G=1,D=2,S=3).
# DRAIN=input, SOURCE=load(+9V), GATE=GND -> body diode conducts input->load,
# blocks on reverse polarity.  Lossless (vs a series Schottky) and DIY-friendly.
q1 = Part("Transistor_FET", "IRF9540N",
          footprint="Package_TO_SOT_THT:TO-220-3_Vertical", ref="Q1")
q1["S"] += v9
q1["G"] += q1g
q1["D"] += vin_raw
R("100k", "R1")[1, 2] += q1g, gnd
Part("Device", "D_Zener", value="12V",
     footprint="Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal", ref="D2")[1, 2] += v9, q1g
Part("Device", "D_TVS", value="P6KE15CA",
     footprint="Diode_THT:D_DO-15_P10.16mm_Horizontal", ref="D1")[1, 2] += v9, gnd
CP("100uF", "C1")[1, 2] += v9, gnd        # input bulk
C("100nF", "C2")[1, 2] += v9, gnd         # input HF bypass

# 5V buck MODULE (synchronous, >90% efficient -> runs cool, NO heatsink needed),
# replacing the LM2596 + its catch diode + inductor. 3-pin 7805-compatible
# pinout (1=VIN, 2=GND, 3=VOUT): a Recom R-78H5.0-2.0 (2A) drops straight in; for
# full Pi 3A headroom, wire a higher-current module (e.g. Pololu D36V28F5) to
# these three pads.
u1 = Part("Regulator_Linear", "L7805",
          footprint="Package_TO_SOT_THT:TO-220-3_Vertical",
          ref="U1", value="DCDC_5V_Buck")
u1[1] += v9            # VIN
u1[2] += gnd           # GND
u1[3] += v5            # VOUT (fixed 5V)
CP("680uF", "C3")[1, 2] += v5, gnd        # output bulk
C("100nF", "C4")[1, 2] += v5, gnd         # output HF bypass

# +5V bulk for Pi inrush + 4x 100nF spread along the GPIO power pins
CP("1000uF", "C5")[1, 2] += v5, gnd
for r in ("C6", "C7", "C8", "C9"):
    C("100nF", r)[1, 2] += v5, gnd

# power-good LED (Device:LED pin1=K, pin2=A)
R("1k", "R4")[1, 2] += v5, pgood
Part("Device", "LED", value="PWR",
     footprint="LED_THT:LED_D3.0mm", ref="D4")[2, 1] += pgood, gnd

# ---- WS2812 level shifters: one 74HCT244 DIP, two of its buffers -----------
# AHCT/HCT TTL inputs accept the Pi's 3.3V as a valid HIGH and output a clean
# 0-5V.  244 group-1: 1A0(2)->1Y0(18) indicator, 1A1(4)->1Y1(16) ring.
u2 = Part("74xx", "74HCT244", footprint="Package_DIP:DIP-20_W7.62mm", ref="U2")
u2[20] += v5            # VCC
u2[10] += gnd          # GND
u2[1] += gnd           # 1OE = enabled
u2[19] += v5           # 2OE = disabled (group 2 unused)
u2[2] += ind_data;  u2[18] += ind_buf
u2[4] += ring_data; u2[16] += ring_buf
u2[6, 8, 11, 13, 15, 17] += gnd   # tie unused inputs low
R("330", "R2")[1, 2] += ind_buf, ind_data_out
R("330", "R3")[1, 2] += ring_buf, ring_data_out
C("100nF", "C10")[1, 2] += v5, gnd

# ---- ring-board connector (8-pin, SAME pinout as the original ring board) ---

j13 = Part("Connector_Generic", "Conn_01x08",
           footprint="Connector_JST:JST_XH_B8B-XH-A_1x08_P2.50mm_Vertical", ref="J13")
j13[1, 2] += v5
j13[3, 4] += gnd
j13[5] += ring_data_out
j13[6] += encA
j13[7] += encB
j13[8] += encSW

# ---- indicator-LED breakout (3-pin) ----------------------------------------

j14 = Part("Connector_Generic", "Conn_01x03",
           footprint="Connector_JST:JST_XH_B3B-XH-A_1x03_P2.50mm_Vertical", ref="J14")
j14[1] += v5
j14[2] += ind_data_out
j14[3] += gnd
C("100nF", "C11")[1, 2] += v5, gnd

# ---- I2C / power-button / 5V-aux headers -----------------------------------

j17 = Part("Connector_Generic", "Conn_01x04",
           footprint="Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical", ref="J17")
j17[1] += v3v3; j17[2] += sda; j17[3] += scl; j17[4] += gnd

j18 = Part("Connector_Generic", "Conn_01x02",
           footprint="Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical", ref="J18")
j18[1] += pwrbtn; j18[2] += gnd

j19 = Part("Connector_Generic", "Conn_01x02",
           footprint="Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical", ref="J19")
j19[1] += v5; j19[2] += gnd        # external 5V bypass (only when U1 unpopulated)

# ---- ERC bookkeeping -------------------------------------------------------

for _n in (gnd, v5, v3v3, v9, vin_raw):
    _n.drive = POWER

ERC()
generate_netlist()
