# VAMP silent footswitch (sheet metal)

Two folded 2.0 mm 5052 parts per pedal (x10) -- same laser+bend+powder
process as the enclosure; the flats ride in `vamp_sheetmetal.zip`.
Real pedal architecture: the BASE is a low open tray whose 18 mm side
walls carry the rear hinge rivets AND act as the down-stop; the PLATE is
a flat treadle with a short front lip and two hinge tabs, every fold
going DOWN inside the tray, so the top has clear space to travel.
The wire routes over the low (8 mm) rear wall -- no hole, no grommet.

## Why it's silent

| Noise source | This design |
|---|---|
| Stomp-switch clack | **Quiet-series lever microswitch** (Cherry DB3 / ZF D4 "silent" class, 2-wire NO -> plugs into the board's JST inputs unchanged) |
| Plate hits the base going down | Treadle lands on **silicone tape** stuck along the side-wall tops (ENGRAVE marks) |
| Return slap going up | M4 retention screw inside the spring; the nyloc closes on a **silicone washer** on the treadle (hidden under the glued pad) |
| Spring twang / wander | Spring captive on the retention screw, seated in the marked greased seat |
| Hinge rattle | 2x O3.2 pivot rivets (one per side, set LOOSE on a washer), greased |

## Assembly (per pedal)

1. Stick silicone tape along both side-wall tops (ENGRAVE marks).
2. Screw the microswitch to the floor (2x M2.3); solder the JST-XH pigtail.
3. Set the two O3.2 hinge rivets through wall + hinge tab with a washer
   between (set LOOSE - the joint must pivot); grease.
4. Bolt the base to the pedestal (4x M3 x 12). Drop the M4 x 25 button
   head into the pedestal deck recess BEFORE seating the base: it passes
   up through floor + spring + treadle; nyloc + silicone washer on top.
   Thread depth sets rest height / spring preload.
5. Route the pigtail over the low rear wall, under the console lid.
6. Glue the `asp1_pad` on the treadle (hides the nyloc + washer).

## Tuning

- Feel: spring spec (O10 x 20 free, ~1.5 N/mm).                # TUNE
- Rest height / preload: retention-screw thread depth.         # TUNE
- Travel: tape thickness (1 mm tape -> 4 mm at the walls).
- Actuation: bend the microswitch lever / shim the switch.     # TUNE

Numbers (from the generator self-checks): travel 4.0 mm at the walls /
4.3 at the toe; hinge pin at (y 35.5, z 10); lip bottom 17 mm, still
12.8 mm up when fully pressed (front wall is 8); wall tops pass through
the 78-wide faceplate slot with 5 mm clearance, hidden under the pad.

Flat offsets use the MEASURED fold model (CenterFoldBendLinePosition:
folded extent = drawn + DED90/2 ~ 1.9 mm), verified against the native
sheet-metal build in the "VAMP silent pedal" Fusion doc. A formal
dev_deduct pass is still owed before fab.
