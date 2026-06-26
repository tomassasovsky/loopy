"""SKiDL generator for the Loopy pedal MAIN board — THT redesign.

Mostly through-hole / hand-solderable re-spin around an **Arduino Pro Micro
(ATmega32U4, USB-C, 5 V/16 MHz)** module that does native class-compliant
USB-MIDI (firmware: MIDIUSB) and drives DIN-5 MIDI OUT on the hardware UART
(Serial1, D1/D0). The module is mounted in the board interior and its USB-C is
cable-extended to the enclosure faceplate, so there is NO board USB receptacle.
No 16U2, no MocoLUFA bridge, no MIDI-merge gate. See
hardware/loopy_pedal_pcb_tht_plan.md.

The Pro Micro is modelled as the two 1x12 pin-socket rows it plugs into
(SparkFun pinout). ring_board.py is unchanged.

Run (from hardware/kicad/):
    python main_board.py     # KICAD_SYMBOL_DIR may override the symbol path
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
    "/Applications/KiCad.app/Contents/SharedSupport/symbols",
    "/usr/share/kicad/symbols",
]
for _d in _SYMBOL_DIRS:
    if _d and os.path.isdir(_d):
        lib_search_paths[KICAD8].append(_d)

# ---- THT footprint helpers -------------------------------------------------

R_FP = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
C_FP = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"


def R(value, fp=R_FP):
    return Part("Device", "R", value=value, footprint=fp)


def C(value, fp=C_FP):
    return Part("Device", "C", value=value, footprint=fp)


def CP(value, fp):
    return Part("Device", "C_Polarized", value=value, footprint=fp)


# ---- nets ------------------------------------------------------------------

gnd = Net("GND")
v5 = Net("+5V")          # 5V logic rail = module VCC (USB VBUS, or onboard reg from RAW)
v5led = Net("+5V_LED")   # buck output: LED ring + indicator + encoder only
v9 = Net("+9V")          # after reverse-polarity Schottky -> buck input AND RAW
vin_raw = Net("VIN_RAW")
uart_tx = Net("UART_TX")  # D1/TX -> MIDI-OUT buffer
uart_rx = Net("UART_RX")  # D0/RX <- opto (DIN MIDI in)
ring_data = Net("RING_DATA")
ring_data_buf = Net("RING_DATA_BUF")
ring_data_out = Net("RING_DATA_OUT")
ind_data = Net("IND_DATA")
ind_out = Net("IND_DATA_OUT")
midi_out_buf = Net("MIDI_OUT_BUF")
midi_in_opto = Net("MIDI_IN_OPTO")
encA = Net("ENC_A")
encB = Net("ENC_B")
encSW = Net("ENC_SW")
rst = Net("RST")          # Pro Micro /RESET: faceplate button + ICSP recovery

# ---- Pro Micro (USB-C) — single Biacco42 ProMicro footprint (24 pads) -------
# Pad numbers / signals per the Biacco42 ProMicro library (promicro.lib):
#   1 TX  2 RX  3 GND 4 GND 5 D2  6 D3  7 D4  8 D5  9 D6  10 D7 11 D8 12 D9
#   13 D10 14 D16 15 D14 16 D15 17 A0 18 A1 19 A2 20 A3 21 VCC 22 RST 23 GND 24 RAW
# (pad 1 = TX is the corner pad next to the USB-C connector.)

pm = Part("Connector_Generic", "Conn_01x24",
          footprint="loopy:ProMicro", ref="J1", value="ProMicro")

sw_pins = {
    "RECPLAY": pm[5],    # D2
    "STOP": pm[6],       # D3
    "UNDO": pm[7],       # D4
    "MODE": pm[8],       # D5
    "TRACK1": pm[9],     # D6
    "TRACK2": pm[10],    # D7
    "TRACK3": pm[11],    # D8
    "TRACK4": pm[12],    # D9
    "CLEAR": pm[13],     # D10
    "BANK": pm[15],      # D14
}

pm[1] += uart_tx          # TX  -> MIDI OUT
pm[2] += uart_rx          # RX  <- MIDI IN (opto)
pm[3] += gnd
pm[4] += gnd
pm[14] += ind_data        # D16 -> indicator strip
pm[16] += ring_data       # D15 -> ring buffer
pm[17] += encA            # A0
pm[18] += encB            # A1
pm[19] += encSW           # A2
# pm[20] A3 -- spare / unconnected
pm[21] += v5              # VCC: regulated 5 V OUTPUT of the module's onboard reg
#                           (also powers the 5 V logic: U1 buffer, U2 opto)
pm[22] += rst             # RST: faceplate reset button + ICSP (J20/J21)
pm[23] += gnd
# RAW fed from the reverse-protected +9V. The chosen module regulates Vin 7-12 V
# on board (a real regulator with headroom, NOT a 6 V-class clone LDO), so 9 V is
# in-spec and yields a solid 5.0 V on VCC. After D1's ~0.35 V Schottky drop RAW
# sees ~8.65 V (still > the 7 V minimum). The buck no longer feeds VCC -- it powers
# only the LED-ring rail (+5V_LED, ~1 A), which the small onboard reg can't source.
pm[24] += v9              # RAW = +9V (reverse-protected) -> onboard reg -> VCC

# ---- footswitches: 100nF debounce + one 2-pin JST per pedal ----------------

sw_nets = {}
for name, pin in sw_pins.items():
    n = Net("SW_" + name)
    pin += n
    sw_nets[name] = n
    C("100nF")[1, 2] += n, gnd

fsw_order = ["RECPLAY", "STOP", "UNDO", "MODE", "TRACK1",
             "TRACK2", "TRACK3", "TRACK4", "CLEAR", "BANK"]
fsw_refs = ["J10", "J11", "J12", "J13", "J14", "J15", "J16", "J17", "J18", "J19"]
for name, ref in zip(fsw_order, fsw_refs):
    jp = Part("Connector_Generic", "Conn_01x02",
              footprint="Connector_JST:JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical",
              ref=ref, value="FSW_" + name)
    jp[1] += sw_nets[name]
    jp[2] += gnd

# ---- U1: 74AHCT125N quad buffer (DIP-14) — ring data + MIDI OUT -------------

buf = Part("74xx", "74AHCT125", value="74AHCT125N",
           footprint="Package_DIP:DIP-14_W7.62mm", ref="U1")
buf[14] += v5
buf[7] += gnd
C("100nF")[1, 2] += v5, gnd
buf[1] += gnd
buf[2] += ring_data
buf[3] += ring_data_buf
buf[4] += gnd
buf[5] += uart_tx
buf[6] += midi_out_buf
buf[10] += v5
buf[9] += gnd
buf[13] += v5
buf[12] += gnd
buf[8].do_erc = False
buf[11].do_erc = False
R("330")[1, 2] += ring_data_buf, ring_data_out
R("330")[1, 2] += ind_data, ind_out

# ---- DIN MIDI OUT (buffered) -----------------------------------------------

j_mout = Part("Connector", "DIN-5_180degree",
              footprint="loopy:MIDI_DIN5_RA", ref="J4", value="MIDI_DIN5_RA")
R("220")[1, 2] += midi_out_buf, j_mout[5]
R("220")[1, 2] += v5, j_mout[4]
j_mout[2] += gnd

# ---- DIN MIDI IN (opto-isolated) -------------------------------------------

j_min = Part("Connector", "DIN-5_180degree",
             footprint="loopy:MIDI_DIN5_RA", ref="J5", value="MIDI_DIN5_RA")
opto = Part("Isolator", "H11L1", footprint="Package_DIP:DIP-6_W7.62mm", ref="U2")
R("220")[1, 2] += j_min[4], opto[1]
opto[2] += j_min[5]
# MIDI 1.0: the IN jack pin 2 (shield) MUST be left unconnected at the receiver
# to preserve opto isolation / avoid ground loops. (Only MIDI OUT grounds pin 2.)
j_min[2].do_erc = False
Part("Device", "D", value="1N4148",
     footprint="Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal",
     ref="D3")[1, 2] += opto[1], opto[2]
opto[6] += v5
opto[5] += gnd
R("10k")[1, 2] += v5, opto[4]
opto[4] += midi_in_opto
midi_in_opto += uart_rx       # opto out straight to D0/RX (no merge gate)

# ---- Power: 9V barrel -> reverse-prot Schottky -> +9V; buck -> +5V_LED ------

DO41 = "Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal"
j_pwr = Part("Connector", "Barrel_Jack",
             footprint="Connector_BarrelJack:BarrelJack_Horizontal", ref="J3")
# CENTER-NEGATIVE (Boss/guitar-pedal standard): the centre/tip pin is GND, the
# sleeve is +9 V. D1 still blocks a wrong (centre-positive) supply -> no damage,
# it just won't power. Silk at J3 marks "9V CTR-".
j_pwr[1] += gnd          # pin 1 = tip / centre = NEGATIVE
j_pwr[2] += vin_raw      # pin 2 = sleeve = +9 V
Part("Device", "D", value="1N5817", footprint=DO41, ref="D1")[1, 2] += v9, vin_raw
Part("Device", "D", value="P6KE13A", footprint=DO41, ref="D2")[1, 2] += v9, gnd
CP("100uF", "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm")[1, 2] += v9, gnd

buck = Part("Connector_Generic", "Conn_01x04",
            footprint="Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical",
            ref="J8", value="BUCK_5V")
buck[1] += v9
buck[2] += gnd
buck[3] += v5led
buck[4] += gnd
CP("470uF", "Capacitor_THT:CP_Radial_D8.0mm_P3.50mm")[1, 2] += v5led, gnd
C("100nF")[1, 2] += v5led, gnd

# No buck->logic OR-diode (D4 removed): the module's onboard regulator makes VCC
# from RAW, so the logic +5 V rail IS the module's VCC. The buck output +5V_LED
# powers only the LED ring / indicator / encoder. In USB-only mode the buck is off
# so the LEDs stay dark and the MCU + logic run from USB VBUS -> VCC, as before.

# ---- ring-board connector (8-pin, unchanged interface) ---------------------

j_ring = Part("Connector_Generic", "Conn_01x08",
              footprint="Connector_JST:JST_XH_B8B-XH-A_1x08_P2.50mm_Vertical",
              ref="J6")
j_ring[1, 2] += v5led
j_ring[3, 4] += gnd
j_ring[5] += ring_data_out
j_ring[6] += encA
j_ring[7] += encB
j_ring[8] += encSW

# ---- indicator LED strip: off-board via 3-pin header -----------------------

j_ind = Part("Connector_Generic", "Conn_01x03",
             footprint="Connector_JST:JST_XH_B3B-XH-A_1x03_P2.50mm_Vertical",
             ref="J7")
j_ind[1] += v5led
j_ind[2] += ind_out
j_ind[3] += gnd
C("100nF")[1, 2] += v5led, gnd

# ---- firmware recovery: faceplate RESET button + ICSP header ----------------
# Normal reflash is just USB-C (1200bps touch -> Caterina bootloader). These two
# headers cover the failure modes WITHOUT opening the enclosure:
#   J20 - 2-pin to an external momentary button across RST->GND. Double-tap forces
#         the bootloader when a hung sketch / failed auto-reset blocks USB upload.
#   J21 - standard 6-pin AVR ISP to un-brick the Caterina bootloader with a USBasp.
j_rst = Part("Connector_Generic", "Conn_01x02",
             footprint="Connector_JST:JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical",
             ref="J20", value="RESET")
j_rst[1] += rst
j_rst[2] += gnd

# ICSP shares the hardware-SPI pins. MISO is D14, which also carries the BANK
# footswitch debounce cap (100nF), so reflash the bootloader at a SLOW ISP clock.
# Pinout (standard 2x3 AVR-ISP):  1 MISO  2 VCC  3 SCK  4 MOSI  5 /RST  6 GND
j_isp = Part("Connector_Generic", "Conn_02x03_Odd_Even",
             footprint="Connector_PinHeader_2.54mm:PinHeader_2x03_P2.54mm_Vertical",
             ref="J21", value="ICSP")
j_isp[1] += sw_nets["BANK"]   # MISO = D14 (PB3)
j_isp[2] += v5                # VCC
j_isp[3] += ring_data         # SCK  = D15 (PB1)
j_isp[4] += ind_data          # MOSI = D16 (PB2)
j_isp[5] += rst               # /RST
j_isp[6] += gnd               # GND

# ---- ERC / netlist ---------------------------------------------------------

for _n in (gnd, v5, v5led, v9):
    _n.drive = POWER

ERC()
generate_netlist()
