# loopy LED strip

Single-LED WS2812B indicator puck for the VAMP console: **one board per
indicator pedal**, sitting under that pedal's small pill diffuser slot in the
faceplate. One board is 16 x 8 mm, 2-layer, 1.6 mm, carrying **1x WS2812B
5050 addressable LED** (with its 100nF 0603 decoupling cap) and **castellated
half-hole pads on both 8 mm ends**.

```
 left edge                                right edge
 [5V ]──── +5V rail (top edge) ──────────────[5V ]
 [DI ]───────────D1──────────────────────────[DO ]
 [GND]──── GND rail (bottom edge) ───────────[GND]
           + full GND pour on the bottom copper
```

## How boards chain

Boards daisy-chain **pedal to pedal with three short wires** (5V / DATA /
GND, same pad order top-to-bottom on both ends — left-end DATA is DIN,
right-end DATA is DOUT) soldered to the castellated end pads. The
castellations also allow butting boards edge-to-edge (the LED sits 8 mm from
each end, so a butted pair keeps a 16 mm pitch) if a bar is ever wanted.

Console usage:

| row           | pedals with LEDs        | boards | LEDs |
| ------------- | ----------------------- | ------ | ---- |
| front row     | TRACK1..TRACK4          | 4      | 4    |
| mid row       | CLEAR, BANK             | 2      | 2    |
| per console   |                         | 6      | 6    |

Feed 5V/GND once (six indicator LEDs draw ~360 mA absolute worst case, far
less in practice). Data enters at DI on the first puck and daisy-chains
through every LED.

## Buy instead of build

Off-the-shelf single-WS2812B modules (round or square breakout pucks, sold in
tens for pocket change) are electrically identical — 5V/DIN/GND/DOUT, one
5050 — and drop into the same slots and wiring. This board exists for a
cleaner form factor and castellated wire pads; use whichever is at hand.

## Ordering (JLCPCB)

- 2-layer, 1.6 mm, any colour; the board is 16 x 8 mm — well under the
  100 x 100 mm cheap-tier limit.
- **Tick the "Castellated Holes" option.** The end pads are full plated 1.6 mm
  pads (0.8 mm drill) centred exactly on the board edge; the castellation
  process mills the edge through them leaving half-holes. Without the option
  the fab may flag the edge-breaking holes.
- Upload `out/loopy_led_strip_gerbers.zip` (gerbers + Excellon drills).
- Parts if hand-placing: 4x WS2812B (5050 PLCC4), 4x 100nF 0603 per segment.

## Regenerating

The board is generated programmatically with KiCad 10's `pcbnew` module —
plain `python3` does **not** have it, use KiCad's bundled interpreter:

```sh
cd hardware/led_strip
/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 ledstrip_pcb.py
```

This runs a geometry assertion suite, builds the board, fills the GND pour and
runs DRC via `kicad-cli` (the run fails loudly if DRC does), and writes to
`out/`:

- `loopy_led_strip.kicad_pcb` — openable in KiCad
- `gerbers/` + `loopy_led_strip_gerbers.zip` — fab package
- `drc.json` — full DRC report (expected: 0 violations, 0 unconnected)

All dimensions (LED count, pitch, rail widths, via rows…) are parameters at
the top of `ledstrip_pcb.py`; the netlist, routing and silkscreen are derived.

Design notes live as comments in the generator — in particular why the +5V
rail runs on the top edge and GND on the bottom (the WS2812B PLCC4 pinout
1=VDD 2=DOUT 3=GND 4=DIN puts VDD/GND on the package diagonal), and why the
data chain hops on the bottom copper (each LED's rail-to-rail decoupling cap
blocks the top-layer corridor).
