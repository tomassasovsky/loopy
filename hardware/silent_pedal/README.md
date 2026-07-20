# VAMP silent footswitch (sheet metal)

Two folded 2.0 mm 5052 parts per pedal (x10) -- same laser+bend+powder
process as the enclosure; the flats ride in `vamp_sheetmetal.zip`.
Conventional pedal construction: rear pin hinge, front return spring,
slotted-flange travel limiter, lever microswitch.

## Why it's silent

| Noise source | This design |
|---|---|
| Stomp-switch clack | **Quiet-series lever microswitch** (Cherry DB3 / ZF D4 "silent" class, 2-wire NO -> plugs into the board's JST inputs unchanged) |
| Plate hits the base going down | Front lip lands on **Ø8 silicone bumpons** stuck on the floor (ENGRAVE marks) |
| Spring return slap going up | M4 limiter screw wears a **Ø6 silicone sleeve** that meets the flange slot's top edge |
| Spring twang / wander | Spring seated on adhesive silicone dots (marked), greased |
| Hinge rattle | M3 x 45 + nyloc through walls + skirts, greased, snug Ø3.4 bores |

## Assembly (per pedal)

1. Stick 2 bumpons on the floor marks; stick silicone dots on the spring mark.
2. Screw the microswitch to the floor (2x M2.3); solder the JST-XH pigtail.
3. Spring on its seat; plate over it; M3 x 45 hinge screw through walls +
   skirts, nyloc snug-not-tight, grease.
4. M4 x 16 through the lip hole + Ø6 silicone sleeve inside the flange slot,
   nyloc loose enough to slide. Rest height = sleeve against the slot top.
5. Glue the `asp1_pad` on the treadle. Bolt to the pedestal (4x M3 x 12).

## Tuning

- Feel: spring spec (Ø10 x 20 free, ~1.5 N/mm).                # TUNE
- Actuation: bend the microswitch lever / shim the switch.     # TUNE
- Travel: ~4 mm at the toe; stack a second bumpon to shorten.

Numbers (from the generator self-checks): plate 75.0 wide in the 78.0 slot,
lip travel 3.7 mm, bumpons engage 0.3 mm before the slot bottom can.
