# VAMP silent footswitch (sheet metal)

Two folded 2.0 mm 5052 parts per pedal (x10) -- same laser+bend+powder
process as the enclosure; the flats ride in `vamp_sheetmetal.zip`.
**Clamshell sustain-pedal construction** (Artesia / M-Audio reference):
the BASE is a shallow tray -- four UNIFORM 18 mm walls (clean look;
only the front one carries the down-stop tape, the sides hold the hinge
pivots, the rear has the wire hole); the PLATE is an inverted tray --
treadle sized exactly to the cast pad (96 x 71, the fold shoulders read
as the metal rim around the pad) with skirts folded down on all four
sides that wrap OUTSIDE the base walls. Corners are LAPPED: the side
flaps carry 2.9 mm wings so their folded edges close each corner -- no
punched relief circles anywhere; the fold-end relief is a 3.5 x 5.5
notch that lives almost entirely inside the bend arc (~0.3 mm of
visible edge). The rear skirt has a 12 mm cable notch aligned with the
wire hole. No polarity switch -- the board input doesn't need one.

## Why it's silent

| Noise source | This design |
|---|---|
| Stomp-switch clack | **Quiet-series lever microswitch** (Cherry DB3 / ZF D4 "silent" class, 2-wire NO -> plugs into the board's JST inputs unchanged) |
| Plate hits the base going down | Treadle lands full-width on **silicone tape** on the front wall top (ENGRAVE mark) |
| Return slap coming back up | The long REAR skirt re-lands on **silicone tape on the pedestal deck** -- a 10 mm lever arm, so contact speed is tiny |
| Spring twang / wander | Spring seated on a dab of RTV in the marked seat (4 mm preload keeps it loaded at rest) |
| Hinge rattle | 2x M4 shoulder screws (O5 x 4 shoulder) + 1 mm washer into PEM CLS-M4 nuts -- 0.5 mm controlled float, greased |

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
   are shallow).
5. Route the pigtail down the rear gap, out under the rear skirt, under
   the console lid to the board.
6. Glue the `asp1_pad` on the treadle. (Service: unscrew the two
   shoulder screws and the whole top lifts off -- the switch is
   reachable without drilling anything.)

## Tuning

- Feel: spring spec (O10 x 25 free, ~1.5 N/mm -> ~6 N preload,
  ~11 N at full press; solid height must be < 15 mm).          # TUNE
- Rest height: rear-skirt deck tape thickness (shim to trim).  # TUNE
- Travel: front-wall tape thickness (1 mm -> 4.0 mm at the wall,
  4.3 at the toe).
- Actuation: bend the microswitch lever / shim the switch.     # TUNE

Numbers (from the generator self-checks): walls uniform 18; clamshell outer 76.8 x 101.8
through the 80 x 105 faceplate slot (FSW_SLOT = footprint + 5); hinge
pivot at (y 40, z 8) -- low enough that the screw head passes under the
faceplate edge; side/front skirt bottoms at 6 mm (1.8 above the deck at
full press), rear skirt rests on the deck tape at 1 mm (the geometric
up-stop: lifting the front digs it in, so the plate is captive).

Flat offsets use the MEASURED fold model (CenterFoldBendLinePosition:
folded extent = drawn + DED90/2 ~ 1.9 mm, measured from the DRAWN face),
verified against the native sheet-metal build in the "VAMP silent pedal"
Fusion doc. A formal dev_deduct pass is still owed before fab.
