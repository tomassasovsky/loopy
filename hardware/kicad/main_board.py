"""SKiDL generator for the Loopy pedal MAIN board (standalone 328P + 16U2).

Produces a KiCad netlist (main_board.net) importable into the PCB editor, plus
an ERC report. Symbol names/pins are for KiCad 10 libraries.

Run (from hardware/kicad/):
    set KICAD8_SYMBOL_DIR=C:\\Program Files\\KiCad\\10.0\\share\\kicad\\symbols
    python main_board.py
"""

from skidl import (
    Part,
    Net,
    generate_netlist,
    ERC,
    POWER,
    set_default_tool,
    KICAD8,
    lib_search_paths,
)

set_default_tool(KICAD8)
lib_search_paths[KICAD8].append(
    r"C:\Program Files\KiCad\10.0\share\kicad\symbols"
)

# ---- helpers ---------------------------------------------------------------

def R(value, fp="Resistor_SMD:R_0603_1608Metric"):
    return Part("Device", "R", value=value, footprint=fp)

def C(value, fp="Capacitor_SMD:C_0603_1608Metric"):
    return Part("Device", "C", value=value, footprint=fp)

# ---- nets ------------------------------------------------------------------

gnd = Net("GND")
v5 = Net("+5V")        # 5V_LOGIC (OR of USB 5V and buck 5V)
v5led = Net("+5V_LED")  # buck only
v9 = Net("+9V")        # after reverse-polarity protection
vbus = Net("VBUS")     # USB 5V
usb_dp = Net("USB_D+")
usb_dm = Net("USB_D-")
uart_tx = Net("UART_TX")   # 328P TXD (PD1)
uart_rx = Net("UART_RX")   # 328P RXD (PD2 of... no: 328P RXD=PD0)
m16_tx = Net("M16_TXD")    # 16U2 PD3 (to merge)
midi_in_opto = Net("MIDI_IN_OPTO")  # H11L1 output -> merge
ring_data = Net("RING_DATA")        # A3 -> buffer
ring_data_buf = Net("RING_DATA_BUF")  # buffer -> cable
ind_data = Net("IND_DATA")          # D2 -> indicator strip
midi_out_buf = Net("MIDI_OUT_BUF")  # 328P TXD -> buffer -> DIN OUT
rst328 = Net("RST_328")
dtr = Net("DTR")
encA = Net("ENC_A")
encB = Net("ENC_B")
encSW = Net("ENC_SW")

# ---- U1: ATmega328P-A (the looper MCU) -------------------------------------

u1 = Part("MCU_Microchip_ATmega", "ATmega328P-A",
          footprint="Package_QFP:TQFP-32_7x7mm_P0.8mm", ref="U1")
# power
u1[4, 6] += v5            # VCC
u1[3, 5, 21] += gnd       # GND
# AVCC via ferrite + decoupling
fb1 = Part("Device", "L", value="FerriteBead",
           footprint="Inductor_SMD:L_0603_1608Metric", ref="FB1")
fb1[1] += v5
fb1[2] += u1[18]          # AVCC
C("100nF")[1, 2] += u1[18], gnd
C("100nF")[1, 2] += u1[20], gnd   # AREF
# clock
y1 = Part("Device", "Crystal", value="16MHz",
          footprint="Crystal:Crystal_SMD_HC49-SD", ref="Y1")
y1[1] += u1[7]            # XTAL1 (PB6)
y1[2] += u1[8]            # XTAL2 (PB7)
C("22pF")[1, 2] += u1[7], gnd
C("22pF")[1, 2] += u1[8], gnd
# decoupling
for _ in range(2):
    C("100nF")[1, 2] += v5, gnd
C("10uF", "Capacitor_SMD:C_0805_2012Metric")[1, 2] += v5, gnd
# reset
R("10k")[1, 2] += rst328, v5
u1[29] += rst328          # PC6/RESET
sw_rst = Part("Switch", "SW_Push", footprint="Button_Switch_SMD:SW_Push_1P1T_NO_CK_KMR2",
              ref="SW1")
sw_rst[1, 2] += rst328, gnd
C("100nF")[1, 2] += dtr, rst328   # DTR auto-reset cap
# signal pins
u1[31] += uart_tx         # PD1 TXD
u1[30] += uart_rx         # PD0 RXD (fed by the MIDI-IN merge)
u1[32] += ind_data        # PD2 -> indicator LED strip
# ADC6/ADC7 unused -> tie to AVCC region GND-free (leave to v5 ref via 0R? -> NC)
# encoder
u1[23] += encA            # PC0 / A0
u1[24] += encB            # PC1 / A1
u1[25] += encSW           # PC2 / A2
u1[26] += ring_data       # PC3 / A3 -> ring buffer

# footswitch nets D3..D12 -> 328P pins
sw_pins = {
    "RECPLAY": 1,   # PD3
    "STOP": 2,      # PD4
    "UNDO": 9,      # PD5
    "MODE": 10,     # PD6
    "TRACK1": 11,   # PD7
    "TRACK2": 12,   # PB0
    "TRACK3": 13,   # PB1
    "TRACK4": 14,   # PB2
    "CLEAR": 15,    # PB3
    "BANK": 16,     # PB4
}
sw_nets = {}
for name, pin in sw_pins.items():
    n = Net("SW_" + name)
    u1[pin] += n
    sw_nets[name] = n
    # hardware debounce: 100nF from the pin to GND (with the internal pull-up)
    C("100nF")[1, 2] += n, gnd

# footswitch connectors (2x 6-pos): 5 switches + GND each
j3 = Part("Connector_Generic", "Conn_01x06",
          footprint="Connector_JST:JST_XH_B6B-XH-A_1x06_P2.50mm_Vertical", ref="J3")
j4 = Part("Connector_Generic", "Conn_01x06",
          footprint="Connector_JST:JST_XH_B6B-XH-A_1x06_P2.50mm_Vertical", ref="J4")
grpA = ["RECPLAY", "STOP", "UNDO", "MODE", "TRACK1"]
grpB = ["TRACK2", "TRACK3", "TRACK4", "CLEAR", "BANK"]
for i, name in enumerate(grpA):
    j3[i + 1] += sw_nets[name]
j3[6] += gnd
for i, name in enumerate(grpB):
    j4[i + 1] += sw_nets[name]
j4[6] += gnd

# ICSP-328P (2x3)
icsp1 = Part("Connector_Generic", "Conn_02x03_Odd_Even",
             footprint="Connector_PinHeader_2.54mm:PinHeader_2x03_P2.54mm_Vertical",
             ref="J6")
icsp1[1] += u1[16]   # MISO (PB4) -- note: PB4 also used as BANK switch; ICSP shares
icsp1[2] += v5
icsp1[3] += u1[17]   # SCK (PB5)
icsp1[4] += u1[15]   # MOSI (PB3)
icsp1[5] += rst328
icsp1[6] += gnd

# ---- U2: ATmega16U2-A (USB-MIDI) -------------------------------------------

u2 = Part("MCU_Microchip_ATmega", "ATmega16U2-A",
          footprint="Package_QFP:TQFP-32_7x7mm_P0.8mm", ref="U2")
u2[4] += v5              # VCC
u2[3, 28] += gnd        # GND, UGND
u2[31] += v5            # UVCC
u2[32] += v5            # AVCC (via bead ideally; tie to 5V for simplicity)
C("100nF")[1, 2] += u2[4], gnd
C("100nF")[1, 2] += u2[31], gnd
C("1uF", "Capacitor_SMD:C_0603_1608Metric")[1, 2] += u2[27], gnd  # UCAP
# clock
y2 = Part("Device", "Crystal", value="16MHz",
          footprint="Crystal:Crystal_SMD_HC49-SD", ref="Y2")
y2[1] += u2[1]          # XTAL1
y2[2] += u2[2]          # PC0/XTAL2
C("22pF")[1, 2] += u2[1], gnd
C("22pF")[1, 2] += u2[2], gnd
# USB data to 16U2 (via 22R series)
r_dp = R("22")
r_dm = R("22")
r_dp[1] += usb_dp
r_dp[2] += u2[29]      # D+
r_dm[1] += usb_dm
r_dm[2] += u2[30]      # D-
# UART link
u2[8] += uart_tx       # 16U2 PD2 = RXD1  <- 328P TXD
u2[9] += m16_tx        # 16U2 PD3 = TXD1  -> merge
# 16U2 reset
rst16 = Net("RST_16")
R("10k")[1, 2] += rst16, v5
u2[24] += rst16        # PC1/~RESET
Part("Switch", "SW_Push", footprint="Button_Switch_SMD:SW_Push_1P1T_NO_CK_KMR2",
     ref="SW2")[1, 2] += rst16, gnd
# DTR auto-reset: 16U2 drives DTR (documented pin); route a free GPIO PC7
u2[22] += dtr          # PC7 as DTR-reset output (firmware-driven)
# dualMoco serial-mode select: MOSI/PB2 (pin16) jumper to GND
jmode = Part("Connector_Generic", "Conn_01x02",
             footprint="Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical",
             ref="J10")
jmode[1] += u2[16]     # PB2 (MOSI) - dualMoco mode pin
jmode[2] += gnd
# ICSP-16U2
icsp2 = Part("Connector_Generic", "Conn_02x03_Odd_Even",
             footprint="Connector_PinHeader_2.54mm:PinHeader_2x03_P2.54mm_Vertical",
             ref="J7")
icsp2[1] += u2[17]   # MISO = PB3
icsp2[2] += v5
icsp2[3] += u2[15]   # SCK = PB1
icsp2[4] += u2[16]   # MOSI = PB2 (also the dualMoco mode-select pin)
icsp2[5] += rst16
icsp2[6] += gnd

# ---- USB-C + ESD -----------------------------------------------------------

j1 = Part("Connector", "USB_C_Receptacle_USB2.0_16P",
          footprint="Connector_USB:USB_C_Receptacle_GCT_USB4085",
          ref="J1")
j1["A1", "B1", "A12", "B12", "SH"] += gnd
j1["A4", "A9", "B4", "B9"] += vbus
j1["A6", "B6"] += usb_dp
j1["A7", "B7"] += usb_dm
R("5.1k")[1, 2] += j1["A5"], gnd   # CC1
R("5.1k")[1, 2] += j1["B5"], gnd   # CC2
esd = Part("Power_Protection", "USBLC6-2SC6",
           footprint="Package_TO_SOT_SMD:SOT-23-6", ref="U7")
esd[5] += vbus
esd[2] += gnd
esd[1, 6] += usb_dp
esd[3, 4] += usb_dm

# ---- Power: 9V barrel -> reverse prot -> AP63203 buck -> 5V_LED -------------

j2 = Part("Connector", "Barrel_Jack",
          footprint="Connector_BarrelJack:BarrelJack_Horizontal", ref="J2")
vin_raw = Net("VIN_RAW")
j2[1] += vin_raw       # center
j2[2] += gnd           # sleeve
# reverse-polarity P-FET (source=VIN_RAW, gate=GND, drain=+9V)
# AO3401A: real ~4A/-30V P-MOSFET, numbered pads (1/2/3) matching SOT-23.
q1 = Part("Transistor_FET", "AO3401A",
          footprint="Package_TO_SOT_SMD:SOT-23", ref="Q1")
q1["S"] += vin_raw
q1["G"] += gnd
q1["D"] += v9
Part("Device", "D", value="TVS_SMBJ12A",
     footprint="Diode_SMD:D_SMA", ref="D1")[1, 2] += gnd, v9
C("22uF", "Capacitor_SMD:C_1206_3216Metric")[1, 2] += v9, gnd
# AP63203WU buck: FB,EN,IN,GND,SW,BST
u3 = Part("Regulator_Switching", "AP63203WU",
          footprint="Package_TO_SOT_SMD:SOT-23-6", ref="U3")
u3[3] += v9             # IN
u3[2] += v9             # EN (tied high)
u3[4] += gnd           # GND
sw_node = Net("SW_NODE")
u3[5] += sw_node       # SW
C("100nF")[1, 2] += u3[6], sw_node   # BST
l1 = Part("Device", "L", value="10uH",
          footprint="Inductor_SMD:L_12x12mm_H8mm", ref="L1")
l1[1] += sw_node
l1[2] += v5led
C("22uF", "Capacitor_SMD:C_1206_3216Metric")[1, 2] += v5led, gnd
C("22uF", "Capacitor_SMD:C_1206_3216Metric")[1, 2] += v5led, gnd
# FB divider for 5.0V (Vref 0.8V): Rtop=52.3k, Rbot=10k
fbnet = Net("FB")
u3[1] += fbnet         # FB
R("52.3k")[1, 2] += v5led, fbnet
R("10k")[1, 2] += fbnet, gnd

# ---- 5V OR-ing: USB 5V and buck 5V -> +5V (logic) --------------------------

# Ideal-diode from buck -> +5V
d_buck = Part("Power_Management", "LM66100DCK",
              footprint="Package_TO_SOT_SMD:SOT-23-6", ref="U5")
d_buck[1] += v5led   # VIN
d_buck[6] += v5      # VOUT
d_buck[2] += gnd     # GND
d_buck[3] += gnd     # ~CE (enabled)
# Ideal-diode from USB VBUS -> +5V
d_usb = Part("Power_Management", "LM66100DCK",
             footprint="Package_TO_SOT_SMD:SOT-23-6", ref="U6")
d_usb[1] += vbus     # VIN
d_usb[6] += v5       # VOUT
d_usb[2] += gnd      # GND
d_usb[3] += gnd      # ~CE

# ---- LED data buffers (74AHCT1G125 x2) -------------------------------------

buf_ring = Part("74xGxx", "74AHCT1G125",
                footprint="Package_TO_SOT_SMD:SOT-23-5", ref="U4")
buf_ring[5] += v5
buf_ring[3] += gnd
buf_ring[1] += gnd          # ~OE = enabled
buf_ring[2] += ring_data    # A
buf_ring[4] += ring_data_buf  # Y
ring_data_out = Net("RING_DATA_OUT")
R("330")[1, 2] += ring_data_buf, ring_data_out  # series to cable

# ---- MIDI OUT (buffered) ---------------------------------------------------

buf_midi = Part("74xGxx", "74AHCT1G125",
                footprint="Package_TO_SOT_SMD:SOT-23-5", ref="U8")
buf_midi[5] += v5
buf_midi[3] += gnd
buf_midi[1] += gnd
buf_midi[2] += uart_tx
buf_midi[4] += midi_out_buf
j_mout = Part("Connector", "DIN-5_180degree",
              footprint="loopy:MIDI_DIN5_RA",
              ref="J8")
R("220")[1, 2] += midi_out_buf, j_mout[5]   # TX -> DIN pin 5
R("220")[1, 2] += v5, j_mout[4]             # +5V -> DIN pin 4
j_mout[2] += gnd                            # DIN pin 2 = shield/GND

# ---- MIDI IN (opto + AND merge) --------------------------------------------

j_min = Part("Connector", "DIN-5_180degree",
             footprint="loopy:MIDI_DIN5_RA",
             ref="J9")
opto = Part("Isolator", "H11L1",
            footprint="Package_DIP:DIP-6_W7.62mm", ref="U9")
# H11L1: 1=anode,2=cathode,3=NC,4=GND,5=Vo,6=Vcc
R("220")[1, 2] += j_min[4], opto[1]      # DIN pin4 (source) via 220R -> anode
opto[2] += j_min[5]                       # DIN pin5 -> cathode
j_min[2] += gnd                          # shield
Part("Diode", "1N4148", footprint="Diode_SMD:D_SOD-123", ref="D2")[1, 2] += opto[1], opto[2]
opto[6] += v5
opto[4] += gnd
R("10k")[1, 2] += v5, opto[5]            # pull-up on Vo
opto[5] += midi_in_opto
# AND-gate merge: inputs = 16U2 TXD + opto out -> 328P RXD
andg = Part("74xGxx", "74AHCT1G08",
            footprint="Package_TO_SOT_SMD:SOT-23-5", ref="U10")
andg[5] += v5
andg[3] += gnd
andg[1] += m16_tx
andg[2] += midi_in_opto
andg[4] += uart_rx

# ---- ring-board connector (8-pin) ------------------------------------------

j5 = Part("Connector_Generic", "Conn_01x08",
          footprint="Connector_JST:JST_XH_B8B-XH-A_1x08_P2.50mm_Vertical", ref="J5")
j5[1, 2] += v5led
j5[3, 4] += gnd
j5[5] += ring_data_out
j5[6] += encA
j5[7] += encB
j5[8] += encSW

# ---- indicator LEDs: broken out to an OFF-board strip via a 3-pin header ----
# The mode / track1-4 / clear / X2 indicator WS2812Bs live on their own board;
# only the series resistor + decoupling stay here. J11 carries +5V / data / GND.
ind_out = Net("IND_DATA_OUT")
R("330")[1, 2] += ind_data, ind_out
j_ind = Part("Connector_Generic", "Conn_01x03",
             footprint="Connector_JST:JST_XH_B3B-XH-A_1x03_P2.50mm_Vertical",
             ref="J11")
j_ind[1] += v5led        # +5V for the off-board LED strip
j_ind[2] += ind_out      # WS2812 data (after the 330R series resistor)
j_ind[3] += gnd
C("100nF")[1, 2] += v5led, gnd   # local decoupling at the header

# Declare the supply rails as power-driven (KiCad PWR_FLAG equivalent): silences
# the "insufficient drive" warnings on the supply pins.
for _n in (gnd, v5, v5led, v9, vbus):
    _n.drive = POWER

# +5V is intentionally diode-OR'd from two ideal-diode outputs (USB + buck).
# Exclude the second output pin from ERC so the legitimate OR isn't flagged.
d_usb[6].do_erc = False

ERC()
generate_netlist()
