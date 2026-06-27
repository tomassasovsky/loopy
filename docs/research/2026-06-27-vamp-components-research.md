---
date: 2026-06-27
topic: vamp-enclosure-components
type: deep-research
---

# VAMP enclosure — component dimensions & integration research

## Executive summary

This report pins the physical facts needed to size the VAMP enclosure's cutouts,
inner pedal platforms, screen apertures and ventilation. The headline finding is
that the three candidate foot pedals are **bulky floor units**, not compact panel
switches: the Artesia ASP-1 is 100 × 75 × 25 mm [1], the Nektar NP-1 is
173 × 78 × 45 mm (6.81 × 3.07 × 1.77 in) [2], and the M-Audio SP-2's dimensions
are unpublished by both the maker and Thomann [3][4]. Integrating ten of these
"as whole pedals standing on platforms" is therefore a real packaging problem and
forces a design choice (embed-whole vs harvest-the-mechanism) that belongs in the
plan. For the displays, a 16" portable touch monitor is ~355 × 223 × 15 mm with a
~354 × 199 mm active area (ViewSonic TD1655) [6], and a 7" 1024 × 600 DSI module
is ~165 × 100 mm outline / ~154 × 86 mm active. For the glowing logo, **edge-lit
engraved PMMA out-performs EL-wire** on brightness and longevity (PMMA does not
yellow; EL-wire fades and needs an inverter) [7]. A Pi 5 draws up to 12 W and its
active cooler ramps from 60 °C, so the sealed aluminium box needs deliberate
ventilation and under-board airflow [8][9].

## Introduction

The brainstorm (`docs/brainstorm/2026-06-27-vamp-enclosure-brainstorm-doc.md`)
settled the architecture — integrated pedals on welded inner platforms, external
audio interface, bottom-plate service — but left every *dimension* open. This
research gathers verifiable measurements for the foot pedals, the 7"/16"
touchscreens, the logo lighting method and Pi thermals, so the parametric
generator (`hardware/enclosure/vamp_enclosure.py`) can be driven by real parts
rather than guesses. Where a manufacturer does not publish a figure, that gap is
stated plainly rather than filled with a fabricated number.

## Finding 1 — The candidate foot pedals are bulky floor units

The Artesia ASP-1 measures **100 × 75 × 25 mm** according to its retail listing [1]
— a thin, flat universal sustain pedal. The Nektar NP-1 is a metal footswitch at
**6.81 × 3.07 × 1.77 in = 173 × 78 × 45 mm** [2], confirmed as an all-metal
"universal footswitch" on Nektar's own product page [3]. The M-Audio SP-2 is a
classic chrome piano-style rocker pedal, but neither M-Audio's site nor Thomann
lists its dimensions [4]; comparable piano-style pedals of that class run roughly
130 × 60 × 55 mm, so treat the SP-2 as *measure-on-arrival*.

The consequence is significant. The reference "Chewie II" foot switches read as
compact rectangular pads roughly 45–55 mm across, whereas these candidates are
75–173 mm in their largest footprint dimension. Standing ten whole pedals on inner
platforms would demand 75–173 mm-long slots and platforms reaching deep into the
465 mm chassis depth — directly competing with the 16" screen for rear space. This
suggests the practical mod is **not** to embed the entire pedal but to **harvest
the internal momentary switch and its rocker/foot-plate** and mount that on the
platform, which is also how a compact reference look is achieved. Of the three,
the Artesia ASP-1 is the most embed-friendly *whole* (thin 25 mm body, flat
100 × 75 footprint), while the Nektar NP-1's all-metal build is the most robust
mechanism to harvest. This is the key open decision for the plan.

## Finding 2 — Touchscreen module envelopes

A 16" portable touch monitor is the right class for the main display. The
ViewSonic TD1655 is **355.46 × 223.44 × 14.7 mm** at 1920 × 1080 with USB-C touch
[6], and competing 16" units cluster at the same ~355 × 223 × 15 mm envelope with
0.3–0.6 in thickness [6]. The 16:9 active area for a 16" panel is ≈ 354 × 199 mm,
so the faceplate aperture should expose ~350 × 199 mm with the ~15 mm-thick module
mounted from behind. At only ~15 mm deep these monitors fit easily under the 45 mm
front / 100 mm rear wedge, but they are HDMI/USB-C bezels (not bare panels), so the
mounting scheme is "clamp the monitor behind a slightly-undersized aperture," not
"drop a bare LCD into a bezel cut."

For the left waveform screen, a 7" 1024 × 600 IPS DSI module (e.g. Waveshare 7"
DSI LCD (C)) has an outline of approximately **165 × 100 mm** with an active area
of **~154 × 86 mm** [5]; the exact outline and any mounting-hole pattern must be
read off the datasheet of the specific module purchased (Waveshare's spec pages
block automated retrieval, so this figure is the standard 7"/1024 × 600 panel
geometry rather than a scraped value). DSI ribbons exit one long edge, which fixes
the screen's rotation and the cable-clearance side inside the box.

## Finding 3 — Logo: edge-lit engraved PMMA beats EL-wire

The reference's glowing "Chewie II" logo is EL-wire. For VAMP, **edge-lit engraved
acrylic is the better method**. Edge-lit panels channel LED light through a clear
acrylic light-guide and glow only where the surface is engraved, giving an even,
elegant line of light [7]. Critically, the light-guide material matters: PS and MS
acrylics yellow within ~2–3 years, whereas **PMMA (cast acrylic) has very high
light transmission and does not yellow with age** [7]. Versus EL-wire, an edge-lit
PMMA bar is brighter, has no inverter or wear-out failure mode, runs off the same
5 V rail as the WS2812 LEDs, and is laser-cut as a flat insert — so it drops into a
recess behind a "VAMP" window in the faceplate. Backlit (LEDs directly behind a
mask) is brighter still but needs 38–64 mm of depth [7], more than the wedge's
front gives, so edge-lit is the right trade.

## Finding 4 — Pi thermals demand real ventilation

The Raspberry Pi 5's BCM2712 draws **up to 12 W under load** [8]. Its Active Cooler
is firmware-managed — fan on at 60 °C, faster at 67.5 °C, full at 75 °C [9] — and
even the official case "gets louder … because the ventilation slots restrict
airflow," with the explicit guidance that sealed enclosures need "standoffs that
allow air circulation" under the board [9]. For VAMP this means the aluminium box
must not be airtight: provide intake/exhaust slots (e.g. on the rear and bottom),
mount the Pi on standoffs off the bottom plate, and keep the Active Cooler's intake
clear. A Pi 4 (≈5–7 W) is easier but the same venting applies. The buck regulator
on `loopy_pi_main` is a second heat source and wants airflow too.

## Synthesis & insights

The research reframes the central problem. The earlier build treated footswitches
as ~50 mm panel features; the real candidate pedals are 75–173 mm floor units, so
the honest design space is (a) **harvest** each pedal's momentary switch + rocker
and mount the harvested mechanism on a small welded platform — compact slots,
reference look, most work per pedal; or (b) **embed the whole thin ASP-1** — bigger
100 × 75 slots, less disassembly, but ten of them eat front-panel real estate; or
(c) **abandon the sustain-pedal route** for purpose-made rectangular momentary
footswitches sized like the reference. The platform height in every case is set by
"datum the pressable top flush/proud with the slot," which can only be finalised
once the chosen mechanism is in hand and measured.

Everything else is now quantified enough to parameterise: the 16" and 7" apertures,
the ~15 mm and DSI-ribbon depths behind them, the edge-lit PMMA logo recess, and a
vented bottom/rear with Pi-on-standoffs. The one measurement that still must come
from the physical part is the pedal-mechanism footprint and height — so the plan
should treat `FSW_*` as provisional until the user measures the chosen pedal.

## Limitations & caveats

The M-Audio SP-2 dimensions could not be verified from any primary source [4]; the
~130 × 60 × 55 mm figure is a class estimate, not a measurement. The Artesia ASP-1
100 × 75 × 25 mm comes from a single retail listing [1] and was not cross-checked
against a manufacturer datasheet. The 7" module outline (~165 × 100 mm) is the
standard 1024 × 600 panel geometry, not a value scraped from the specific Waveshare
page (which returned HTTP 403) [5]; confirm against the exact SKU. The logo and
thermal findings are from general edge-lit-panel and Raspberry Pi sources [7][8][9],
not from a build identical to VAMP, so treat brightness/airflow as directionally
correct and prototype-verify.

## Recommendations

Immediate: (1) pick **one** pedal as the build target and **measure its rocker /
foot-plate and mechanism height in person** before committing `FSW_*`; the Nektar
NP-1's metal mechanism is the most robust to harvest, the Artesia ASP-1 the easiest
to embed whole. (2) Specify the 16" main aperture at ~350 × 199 mm and the 7" at
~156 × 88 mm, both mounted from behind, and confirm against the purchased modules.
(3) Adopt an **edge-lit engraved PMMA** "VAMP" insert (cast PMMA, 5 V LED edge
strip) rather than EL-wire. (4) Make the chassis vented — rear + bottom slots, Pi
on standoffs, Active Cooler intake clear.

Next: feed these into the plan as parameters, marking `FSW_*` provisional; design
the welded platform as a height-adjustable shim stack so the foot-plate datum can
be tuned after measuring the pedal.

Further research: obtain the chosen pedal's exploded view / service manual for the
switch-mechanism footprint; pull the exact datasheet of the specific 7" and 16"
modules once selected.

## Bibliography

[1] Amazon.com. "Artesia ASP-1 Universal Sustain Pedal." Product listing (dimensions 100 × 75 × 25 mm). https://www.amazon.com/Artesia-Universal-Sustain-Electronic-Keyboards/dp/B0845DNH82 (Retrieved 2026-06-27)

[2] Amazon.com. "Nektar NP-1 Metal Foot Switch/Sustain Pedal, 3.07 x 1.77 x 6.81 inches." Product listing. https://www.amazon.com/Nektar-NP-1-Foot-Switch/dp/B00KIXUG5I (Retrieved 2026-06-27)

[3] Nektar Technology. "NP-1, NP-2, NP-X — Footswitches / Universal Expression Pedals." https://nektartech.com/np-1_np-2_nx-p/ (Retrieved 2026-06-27)

[4] Thomann / M-Audio. "M-Audio SP-2 Professional Piano Style Pedal" (dimensions not published). https://www.thomannmusic.com/maudio_sp2.htm ; https://www.m-audio.com/accessories/sp-2.html (Retrieved 2026-06-27)

[5] Waveshare. "7inch Capacitive Touch IPS Display for Raspberry Pi, 1024×600, DSI Interface (7inch DSI LCD (C))." Product/wiki pages (spec retrieval blocked HTTP 403; figures are standard 1024×600 7" panel geometry). https://www.waveshare.com/7inch-dsi-lcd-c.htm (Retrieved 2026-06-27)

[6] ViewSonic. "TD1655 16" Touch Portable Monitor" — 355.46 × 223.44 × 14.7 mm, 1920 × 1080, USB-C touch. https://www.viewsonic.com/eu/products/lcd/TD1655 (Retrieved 2026-06-27)

[7] TAP Plastics / SwitchToLED. "Chemcast Edge-lit Acrylic" and "Difference Between Backlit and Edge-Lit LED Panels" (PMMA light-guide does not yellow; edge-lit vs backlit thickness/brightness). https://www.tapplastics.com/product/plastics/cut_to_size_plastic/chemcast_edgelit_acrylic ; https://switchtoled.com/blogs/blog-post/difference-between-backlit-and-edge-lit-led-panels (Retrieved 2026-06-27)

[8] Raspberry Pi Ltd. "Heating and cooling Raspberry Pi 5" (BCM2712 up to 12 W). https://www.raspberrypi.com/news/heating-and-cooling-raspberry-pi-5/ (Retrieved 2026-06-27)

[9] The Pi Hut. "Does my Raspberry Pi 5 need a heatsink/fan?" and Raspberry Pi Active Cooler product brief (fan thresholds 60/67.5/75 °C; sealed-case airflow guidance). https://support.thepihut.com/hc/en-us/articles/13852731055517 ; https://datasheets.raspberrypi.com/cooling/raspberry-pi-active-cooler-product-brief.pdf (Retrieved 2026-06-27)

## Methodology appendix

Sources were gathered via parallel web search and targeted page fetches on
2026-06-27. Dimensional claims are cited to the specific retail or manufacturer
listing they came from; where a primary dimension was unavailable (M-Audio SP-2,
the exact Waveshare outline behind an HTTP 403), the gap is stated rather than
filled. Each hardware figure was taken at face value from a single authoritative
listing and flagged for in-person confirmation before being committed to the
parametric generator — appropriate for a build where a wrong cutout means re-cut
metal. Pedal-mechanism footprints and exact module outlines remain the two figures
that must be measured from the physical parts.
