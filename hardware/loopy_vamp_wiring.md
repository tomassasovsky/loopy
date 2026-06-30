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
| Control board → engine | USB (Pi USB hat) | USB (to host) |
| Screens driven by | the Pi (HDMI ×2 + USB-hat touch) | the external host (HDMI in ×2 + USB touch) |
| Rear I/O sub-panel | 9V + btn + fuse + **Pi USB/Ethernet block** | 9V + btn + fuse + **2× HDMI + 2× USB-touch** |
| Audio interface | USB → Pi | USB → host |

---

## 1. Block diagram

> **Constraint:** the main board is already in production — it is NOT modified. Every
> addition below (the high-current 5V buck, the Pi's USB hat) is an **external add-on**;
> the 9V is split at the panel jack, ahead of the board.

```
   POWER
     9V DC barrel (center +, fused) ── rear panel jack
              │
              ├──────────────────► MAIN BOARD J3  (in production — untouched)
              │                       onboard MP1584 buck → 5V
              │                         ├─► Pro Micro            (5V_LOGIC)
              │                         └─► WS2812 indicator+ring (5V_LED)
              │
              └──────────────────► EXTERNAL 9V→5V buck  (≈ 5V/10A add-on module)
                                      ├─► Raspberry Pi          (5V into USB-C)
                                      └─► 7" + 16" screens      (5V)

   DATA / CONTROL
     Pro Micro ──USB──► [USB HAT on the Pi] ◄──USB── 2× screen touch     (add-on hat)
     Pi ──HDMI ×2──► 7" (left) + 16" (right) screens
     Pi rear USB-A ──► external audio interface ;  Pi Ethernet ──► network
     Pro Micro ◄── footswitches ×10 (D3–D12) · ring+encoder (8-pin cable) · MIDI DIN in/out
     power button ──► Pi GPIO (soft shutdown)

   GND: single common ground; DIN IN opto-isolated; M6 earth stud on the rear wall
```

---

## 2. Power distribution

**Two 5V bucks, because the main board is fixed.** The in-production control board
has its own onboard MP1584 (≈3A) fed from its `J3` 9V input — that already powers the
Pro Micro and the WS2812 strips, and **we leave it alone**. The Pi + screens draw far
more than that buck can give, so they get a **separate, external high-current buck**.

- The rear panel-mount **9V barrel jack** (fused, center-positive) is **split with a
  short Y-lead**: one branch to the board's `J3` (its onboard buck → logic + LEDs,
  unchanged), the other to the **external 9V→5V buck**. The split is in the harness,
  ahead of the board — nothing on the board changes.
- **External buck → 5.0V, sized for the Pi + screens (≈ 8–10A).** Feed the **Pi via
  its USB-C** (uses the Pi's own input protection — cleanest). Feed the screens 5V
  from the same buck.
- **You cannot put 9V on the Pi** — every Pi power input (USB-C, GPIO 5V pins) is 5V
  only; 9V would destroy it. The external buck is what makes the 5V.
- Add input bulk/TVS on the external buck's 9V input; keep the board's existing bulk
  as-is.

**Current budget (Pi build, worst case):**

| Load | Rail | Typical | Peak |
|---|---|---|---|
| Pro Micro + footswitches | board buck | 0.05 A | 0.05 A |
| WS2812 indicators (7) + ring (12) = 19 | board buck | 0.2 A | 1.1 A (all white) |
| Raspberry Pi (Pi 5 under load) | **external buck** | 1.0 A | 2.4 A |
| 7" + 16" touchscreens | **external buck** | 1.5 A | 3.0 A |
| Pro Micro + 2× touch via the Pi's USB hat | external buck (via Pi) | 0.1 A | 0.2 A |
| External audio interface (USB-bus-powered) | external buck (via Pi) | 0.2 A | 0.5 A |
| **Board buck** | | ~0.3 A | ~1.4 A |
| **External buck** | | ~2.8 A | ~6.1 A |

→ External buck rated **≥ 8A @ 5V**. The 9V brick must cover both bucks: ~7.5A @ 5V
total ≈ **~50W**, so a **9V/6A (54W) supply** or larger.

**Power button** → Pi GPIO (soft shutdown / wake), not a hard 5V cut, so the Pi can
flush the SD card. The fuse protects the shared 9V input.

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

- **Power** — 5 V from the **external buck into the Pi's USB-C** (see §2). Not 9V,
  not the board's small buck.
- **USB hat (add-on)** — a USB hat on the Pi adds **internal** USB ports, so the
  internal devices don't consume the rear ports:
  - **Pro Micro → USB hat** — control/MIDI data (keeps the existing USB-MIDI firmware;
    the Pi runs the looper engine).
  - **2× screen touch → USB hat.**
- **Screens** — 2× micro-HDMI → 7" (left) + 16" (right) for video; touch over the USB
  hat above. Screen 5V from the external buck.
- **Audio interface** — external USB audio interface on a **rear** Pi USB-A port (line
  in/out live outside the box); the rear ports stay free for it because the internal
  devices are on the hat.
- **Front I/O flush at the rear panel** — the Pi rides 38 mm risers so its rear-edge
  port stack (USB-A ×2 + Gigabit Ethernet) sits flush in the rear-wall window. The
  other Pi edge (USB-C power, micro-HDMI) faces inward; those cables route internally
  to the external buck / screens / USB hat.

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
