# loopy LED strip

Pedal-width WS2812B indicator-strip segment for the VAMP console: **one
segment per indicator pedal**, sitting under that pedal's diffuser slot in the
faceplate. One segment is a 75 x 8 mm (75 mm = the ASP-1 pedal width),
2-layer, 1.6 mm PCB carrying **3x WS2812B 5050 addressable LEDs at 25 mm
pitch** (each with its own 100nF 0603 decoupling cap) and **castellated
half-hole pads on both 8 mm ends**.

```
 left edge                                                   right edge
 [5V ]────────── +5V rail (top long edge, 1.5 mm) ───────────────[5V ]
 [DI ]───D1──▶───D2──▶───D3────────────────────────────────────── [DO ]
 [GND]────────── GND rail (bottom long edge, 1.5 mm) ────────────[GND]
                 + full GND pour on the bottom copper
```

## How segments chain

Segments daisy-chain **pedal to pedal with three short wires** (5V / DATA /
GND, same pad order top-to-bottom on both ends — left-end DATA is the
segment's DIN, right-end DATA its DOUT) soldered to the castellated end pads.
The castellations also still allow butting two segments edge-to-edge into a
continuous bar (LED1/LED3 sit 12.5 mm from their edges, so the 25 mm pitch is
preserved across a butt seam) if a longer run is ever wanted.

Console usage:

| row           | pedals with LEDs        | segments | LEDs |
| ------------- | ----------------------- | -------- | ---- |
| front row     | TRACK1..TRACK4          | 4        | 12   |
| mid row       | CLEAR, BANK             | 2        | 6    |
| per console   |                         | 6        | 18   |

Feed 5V/GND at one end (and re-feed every few segments if you extend further —
the 1.5 mm rails are sized for a handful of segments, not metres). Data enters
at DI on the first segment and daisy-chains through every LED.

## Ordering (JLCPCB)

- 2-layer, 1.6 mm, any colour; the board is 75 x 8 mm — well under the
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
