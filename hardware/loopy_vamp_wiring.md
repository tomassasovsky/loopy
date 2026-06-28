# VAMP loopstation — system wiring plan

How the VAMP's subsystems connect: the THT **Pro Micro control board**
(`hardware/kicad/loopy_pedal_main`), the **ring board** (`loopy_pedal_ring`), the
**Raspberry Pi** (Pi build only), the two touchscreens, the external audio
interface, power, and the rear panel.

There are two builds (selectable in the 3D viewer). They share the **one control
board**; they differ only in whether a Pi is present and what the rear I/O exposes:

| | **Pi build** | **Base build** |
|---|---|---|
| Looper engine | Raspberry Pi (on-board) | external host (laptop/desktop) |
| Control board → engine | USB (Pi USB port) | USB (to host) |
| Screens driven by | the Pi (HDMI ×2 + USB touch) | the external host (HDMI in ×2 + USB touch) |
| Rear I/O sub-panel | 9V + btn + fuse + **Pi USB/Ethernet block** | 9V + btn + fuse + **2× HDMI + 2× USB-touch** |
| Audio interface | USB → Pi | USB → host |

---

## 1. Block diagram

```
                          ┌──────────────────── 9V DC barrel (center +, fused, rear panel) ───────────────────┐
                          │                                                                                    │
                          ▼                                                                                    │
              TVS + reverse-polarity P-MOSFET                                                                  │
                          │                                                                                    │
                          ▼                                                                                    │
                MP1584 buck → 5V  (size for the WHOLE load, see §2)                                            │
                          │                                                                                    │
        ┌─────────────────┼───────────────────────────┬──────────────────────────┬──────────────────┐         │
        ▼                 ▼                           ▼                          ▼                  ▼         │
   5V_LED rail       5V_LOGIC rail               Raspberry Pi 5V            Screen 5V          (power button   │
   (WS2812s)         (Pro Micro)                 (GPIO 5V pins 2/4)         (7" + 16")          → Pi shutdown) │
        │                 │                           │                          │                            │
        │                 │  ┌── USB (data + MIDI) ───┤                          │                            │
        │                 │  │                         ├── HDMI ×2 ──────────────►│ (7" left, 16" right)       │
        │                 ▼  ▼                         ├── USB ×2 (touch) ────────►│ touch panels               │
        │          ┌─────────────────┐                 ├── USB ── external audio interface ──► (line in/out)   │
        │          │  Pro Micro 32U4 │                 └── USB-A / Ethernet ──────► REAR PANEL (Pi build)      │
        │          │  control board  │                                                                         │
        │          └─────────────────┘                                                                         │
        │            │   │   │   │  └── DIN MIDI OUT (74AHCT125 buffer) ──► rear/edge DIN-5                     │
        │            │   │   │   └───── DIN MIDI IN  (H11L1 opto)        ◄── rear/edge DIN-5                    │
        │            │   │   └───────── 8-pin cable ──► RING BOARD: 12× WS2812 ring + EC11 encoder             │
        │            │   └───────────── D3..D12 (RC debounce, JST-XH) ──► 10 footswitches (pedals)             │
        └────────────┴───────────────── D2 → 7× WS2812 indicator strip (Mode/Track1-4/Clear/Bank)             │
                                                                                                              │
   chassis GND ◄── single common ground (DIN IN opto-isolated to break loops); earth stud on rear wall ──────┘
```

---

## 2. Power distribution

**Source topology — one rail feeds everything.** Don't make the Pi redistribute
power. The 9V→5V **buck is the primary 5V source**; the Pi is just another load on
it. This avoids the Pi's input polyfuse / trace current limits (back-feeding the
Pi's 5V GPIO pins bypasses its input protection, so the 5V must be clean and
current-limited, and **do not also plug a USB-C supply into the Pi**).

- **9V DC** (rear barrel, center-positive, fused) → TVS (SMBJ12A) + reverse-polarity
  P-MOSFET → **MP1584/MP2315 buck set to 5.0 V**.
- The buck's 5 V splits into: `5V_LED` (WS2812 strips), `5V_LOGIC` (Pro Micro),
  **Pi 5 V** (into GPIO pins 2/4), **screen 5 V**.
- Bulk: 1000 µF across `5V_LED` at each board's first LED, 100 nF per ~4 LEDs.

**Current budget (Pi build, worst case):**

| Load | Typical | Peak |
|---|---|---|
| Pro Micro + footswitches | 0.05 A | 0.05 A |
| WS2812 indicators (7) + ring (12) = 19 | 0.2 A | 1.1 A (all white) |
| Raspberry Pi (Pi 5 under load) | 1.0 A | 2.4 A |
| 7" + 16" touchscreens | 1.5 A | 3.0 A |
| External audio interface (USB-bus-powered) | 0.2 A | 0.5 A |
| **Total 5 V** | **~3 A** | **~7 A** |

→ Use a **5 V rail rated ≥ 8 A** (one big buck, or split: a logic/LED buck + a
screen/Pi buck). A 9 V/10 A (90 W) brick comfortably covers it. The MP1584 (3 A) on
the existing control board only carries the **logic + LED** share (~1.4 A) — the Pi
and screens want their own bigger buck.

**Power button** → Pi GPIO (soft shutdown / wake), not a hard 5 V cut, so the Pi can
flush the SD card. The fuse protects the 9 V input.

---

## 3. Control board (Pro Micro) — I/O

Unchanged from the standalone pedal design (`loopy_pedal_pcb_design.md`):

- **Footswitches** — D3..D12, each a 2-pin JST-XH header with hardware RC debounce,
  one per pedal (10 total: REC/PLAY, STOP, UNDO, MODE, TRACK1–4, CLEAR, BANK).
- **Indicator LEDs** — D2 → 7× WS2812 on the main board (330 Ω series). Index 0 Mode,
  1–4 Track1–4, 5 Clear, 6 Bank.
- **Ring + encoder** — A3 → ring data (via a 74AHCT125 buffer) and A0/A1/A2 → EC11,
  all over **one 8-pin cable** to the ring board (12× WS2812 ring + encoder).
- **MIDI** — DIN-5 IN through an H11L1 optocoupler (breaks ground loops); DIN-5 OUT
  through a 74AHCT125 buffer; the same 31250-baud stream is mirrored to USB.
- **USB** — the Pro Micro's native USB carries the pedal protocol (USB-MIDI/serial).

---

## 4. Raspberry Pi connections (Pi build)

- **Power** — 5 V from the common buck into GPIO pins 2/4 (see §2).
- **Data from the control board** — **USB**: Pro Micro → a Pi USB-A port. One cable
  carries the control/MIDI data (keeps the existing USB-MIDI firmware). The Pi runs
  the looper engine. (A GPIO-UART link also works — the protocol is already 31250
  UART — but needs 5 V↔3.3 V level shifting and burns the Pi's only hardware UART, so
  USB is preferred.)
- **Screens** — 2× micro-HDMI → 7" (left) + 16" (right); 2× USB → the screens' touch
  panels.
- **Audio interface** — external USB audio interface on a Pi USB port (line in/out
  live outside the box).
- **Front I/O at the rear panel** — the Pi rides 38 mm risers so its rear-edge port
  stack (USB-A ×2 + Gigabit Ethernet) protrudes through the rear sub-panel's
  port-block cutout. The other Pi edge (USB-C, micro-HDMI, audio) faces inward; those
  cables route internally to the screens / buck.

---

## 5. Rear panel mapping

The welded rear wall has a fixed **window**; a bolt-in **sub-panel** carries the
build-specific cutouts:

- **Both builds:** 9 V barrel, power/shutdown button, fuse, an earth stud, and the
  exhaust vent array beside the window.
- **Pi build sub-panel:** one **port-block cutout** framing the Pi's USB-A ×2 +
  Ethernet directly.
- **Base build sub-panel:** **2× HDMI** (video in for the two screens) + **2× USB**
  (touch out to the external host).

DIN-5 MIDI jacks live on the control board's edge (internal, or brought to a side
cutout); the external audio interface is outside the box on a USB lead.

---

## 6. Grounding & ventilation

Single common ground; the DIN **IN** is opto-isolated to break ground loops. An M6
earth stud on the rear wall bonds the chassis. The Pi sits on its risers in the
rear bay with vent slots in the bottom plate (intake, between the platform rows) and
the rear wall (exhaust) — air crosses the boards/Pi and the Pi's active cooler.

---

*Provisional pending a build: exact buck sizing/splitting and the screen power method
(buck vs separate brick) depend on the final screen modules chosen.*
