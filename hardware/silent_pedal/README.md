# VAMP silent footswitch (sheet metal)

Two folded 1.5 mm CRS STEEL parts per pedal (x10) -- the commercial
sustain-pedal material; same vendor + powder run as the enclosure
(second material line-item); the flats ride in `vamp_sheetmetal.zip`.
**Clamshell sustain-pedal construction** (Artesia / M-Audio reference):
the BASE is a shallow tray -- four UNIFORM 18 mm walls (only the front
one carries the down-stop tape, the sides hold the hinge pivots, the
rear has the wire hole). The PLATE is an inverted tray -- treadle
sized exactly to the cast pad (96 x 71, the fold shoulders read as the
metal rim around the pad) with skirts folded down on all four sides
that wrap OUTSIDE the base walls. CORNERS on both parts use the
console-base overlap pattern (the vamp_base rear corners): the
front/rear flaps run FULL OUTER WIDTH and fold over the side flaps'
end edges, closing every corner with metal from the same blank -- no
welds, no filler, and NO relief holes at all: the side folds stop
clear of the front/rear bend bands (a straight wall end cannot
intrude into the neighbour's bend arc), so the folds never cross and
the panel corners stay intact. The ~2 mm interior setback this leaves
between a side wall's end and the crossing wall is fully covered by
the overhanging flap outside. The rear skirt has a 12 mm cable notch aligned with the wire
hole. No polarity switch -- the board input doesn't need one.

## Why it's silent

| Noise source | This design |
|---|---|
| Stomp-switch clack | **Quiet-series lever microswitch** (Cherry DB3 / ZF D4 "silent" class, 2-wire NO -> plugs into the board's JST inputs unchanged) |
| Plate hits the base going down | Treadle lands full-width on **silicone tape** on the front wall top (ENGRAVE mark) |
| Return slap coming back up | The long REAR skirt re-lands on **silicone tape on the pedestal deck** -- a 10 mm lever arm, so contact speed is tiny |
| Spring twang / wander | Spring seated on a dab of RTV in the marked seat (4 mm preload keeps it loaded at rest) |
| Hinge rattle | 2x M4 shoulder screws (O5 x 3 shoulder) + 1 mm washer into PEM CLS-M4 nuts (the CLS series is made for steel sheet) -- 0.5 mm controlled float, greased |

## Assembly (per pedal)

1. Press the two PEM CLS-M4 nuts on the wall INNER faces; stick silicone
   tape full-width on the front (18 mm) wall top and a strip on the
   pedestal deck where the rear skirt lands.
2. Screw the microswitch to the floor (2x M2.3 -- head reliefs are
   pocketed in the deck); solder the JST-XH pigtail and feed it out the
   rear-wall O6 hole. RTV the spring on its seat.
3. Lower the plate over the base (skirts outside the walls, spring
   compresses ~4 mm); drive the two shoulder screws from outside through
   skirt + washer into the PEMs. The shoulder bottoms on the PEM face --
   torque does not clamp the pivot. Grease.
4. Bolt the base to the pedestal (4x M3 x 6 -- short, the insert pilots
   are shallow). Mount pattern 52 x 72 (clear of the bend bands).
5. Route the pigtail down the rear gap, out under the rear skirt, under
   the console lid to the board.
6. Glue the `asp1_pad` on the treadle. (Service: unscrew the two
   shoulder screws and the whole top lifts off -- the switch is
   reachable without drilling anything.)

## Tuning

- Feel: spring spec (O10 x 25 free, ~1.5 N/mm -> ~4.5 N preload,
  ~11 N at full press; solid height must be < 15 mm).          # TUNE
- Rest height: rear-skirt deck tape thickness (shim to trim).  # TUNE
- Travel: front-wall tape thickness (1 mm -> 4.0 mm at the wall,
  4.3 at the toe).
- Actuation: bend the microswitch lever / shim the switch.     # TUNE

Numbers (from the generator self-checks): walls uniform 18; clamshell
outer 75.1 x 100.1 through the 79 x 104 faceplate slot (FSW_SLOT =
footprint + 4); hinge pivot at (y 36.5, z 8) -- low enough that the screw
head passes under the faceplate edge; side/front skirt bottoms at 6 mm
(1.8 above the deck at full press), rear skirt rests on the deck tape
at 1.5 mm (the geometric up-stop: lifting the front digs it in, so the
plate is captive). Spring O10 x 25 free -> ~4.5 N preload at rest.

Flat offsets use the MEASURED fold model (CenterFoldBendLinePosition:
folded extent = drawn + DED90/2, = 1.30 mm for 1.5 CRS R1.5 K0.44 --
re-verified by probing the native steel build in the "VAMP silent
pedal" Fusion doc). A formal dev_deduct pass is still owed before fab.
