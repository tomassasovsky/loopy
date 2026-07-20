# VAMP silent footswitch

Printable replacement for the 10 purchased ASP-1 pedals. Same 75×100×25
envelope, mounts on the printed pedestals' existing M3 inserts, wears the
`asp1_pad` silicone pad on top. Generator: `silent_pedal.py` (cadquery) →
`out/` STEP/STL for base + plate + assembly.

## Why it's silent

| Noise source (stock pedals) | This design |
|---|---|
| Mechanical switch clack | **Reed switch + magnet** — contactless, passive 2-wire, reads as a plain closure on the main board's 2-pin JST inputs |
| Plate slams the body at the end of travel | Lands on **4× Ø8 silicone bumpons** seated in the base rim bosses |
| Spring-return slap on release | Retention screw head lands on a **silicone/EPDM M3 washer** in the plate counterbore (hidden under the glued pad) |
| Spring twang | Spring is **captive on the screw** in greased pockets |
| Hinge rattle | Snug printed knuckles + greased 3 mm steel pin |

## Assembly (per pedal)

1. Melt the M3 insert into the spring boss; stick 4 bumpons in the rim seats.
2. Lay the reed in its floor channel (dab of silicone), solder the JST-XH
   pigtail, route out the side notch. Press the Ø5×2 magnet into the post.
3. Plate on, slide the 58 mm pin through towers + knuckles (dab of grease).
4. Spring over the screw, silicone washer under the head, thread into the
   insert. **Rest height / preload = how deep you thread it.**
5. Glue the `asp1_pad` on top (covers the screw). Bolt down with 4× M3×12.

## Tuning (hardware is never the paper ideal)

- **Actuation point**: `MAGNET_FACE_Z` (reprint the plate) or shim the magnet
  pocket. Design: gap 7.5 mm at rest → 2.7 mm pressed; typical Ø5×2 N35 +
  KSK-1A66 closes at ~4 mm, releases ~6 mm. Verify with a multimeter before
  final assembly — reed sensitivity varies unit to unit.
- **Feel**: spring spec (Ø10×20 free, ~1.5 N/mm) and screw preload.
- **Travel**: 5.5 mm at the toe (bumpon boss height sets it).
