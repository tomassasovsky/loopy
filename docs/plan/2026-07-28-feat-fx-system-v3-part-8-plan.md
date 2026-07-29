---
title: "feat(hardware): stereo TRS jack on the pedal (expression / FS-6)"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Fable at high effort · `autonomy:blocked-verify` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Add a stereo TRS jack to the Loopy pedal so an expression pedal or an
FS-6-style dual footswitch can drive the FX system: the pedal reads the jack
on a single ADC pin, decodes it via a resistor ladder, and emits absolute
MIDI CCs on the existing USB cable that part 7's continuous and discrete
triggers consume with zero extra app plumbing [A10]. This is **PCB rework on
`hardware/kicad/main_board.py`** — the Pro Micro has zero free GPIO [R7] —
plus firmware ADC/decode work and a jack-type setting surfaced in the app.
Tracked as its own child issue (`blocked-verify`); it depends on — but does
**not** gate — the epic's close, which lands on software-only criteria.

## Dependencies

- **Part 7** — `2026-07-28-feat-fx-system-v3-part-7-plan.md` (expression +
  external MIDI): must merge first. It provides the two trigger shapes this
  part targets — continuous CC (`ContinuousBinding`, absolute 0–127, LO/HI)
  and discrete on/off CC (threshold) driving toggle/momentary bindings — plus
  MIDI-learn, smoothing, and the `ControlCubit` dispatch point. The TRS jack
  is just another CC source to that layer.

## Context

**Pin reality [R7]: the Pro Micro has zero free GPIO.** The pinmap in
`hardware/kicad/main_board.py` is **user-verified — do not assume, do not
"fix" it** (review agents have previously false-flagged it as mirrored; RAW
is at the USB end):

- `D16` → indicator strip data, `D15` → ring buffer data (WS2812 outputs,
  `main_board.py:102-103`); both are also committed to the ISP header
  (SCK/MOSI, `main_board.py:273-274`).
- `A2` → encoder push switch net `ENC_SW` (`main_board.py:106`) — **declared
  but never read by firmware**: `firmware/loopy_pedal/loopy_pedal.ino:58`
  ("the push switch on A2 is unused in v1"; see also `:45`).
- `A3` → LED-rail power sense divider (`main_board.py:107-114`).

**Pinned direction [R7]:** repurpose **A2** — cut the never-read `ENC_SW`
net — and use a **single-pin resistor-ladder TRS decode on A2 alone** that
distinguishes an expression wiper from FS-6 tip/ring switch combinations
without a second pin. Alternatives if the ladder proves unreliable on the
bench: free a pin by dropping DIN MIDI IN (D0), or an I/O expander / respin.
Verify on the bench; nothing here is assumable from the schematic alone.

Rejected alternatives (lifted from the epic's alternatives table):

| Approach | Why rejected |
|----------|--------------|
| Mono TS expression jack | User requires stereo TRS for FS-6-class accessories |
| Second GPIO for the TRS ring | No free pin exists on the board; single-pin resistor ladder on a repurposed A2 [R7] |

Key files:

- `hardware/kicad/main_board.py` — PCB generator (the rework target)
- `firmware/loopy_pedal/loopy_pedal.ino` — pedal firmware (ADC + decode +
  CC emit + config)
- `firmware/loopy_pedal/pedal_protocol.{h,c}` + `firmware/test/` — protocol
  copies and contract-test runner (`firmware/test/run_tests.sh`, created in
  part 5); firmware changes here must keep it green
- `hardware/loopy_pedal_pcb_design.md`, `hardware/loopy_pedal_pcb_tht_plan.md`,
  `hardware/loopy_pedal_shopping_list.md` — hardware docs to update
- Part 7's learn hygiene [B8] ignores the pedal's own protocol traffic (note
  range + relative encoder CC) — the TRS CC numbers must fall **outside**
  that ignored set or they can never be learned

Constraints carried from the epic:

- Values are sent as **absolute CCs on the existing cable**, consumed by
  part 7's triggers [A10] — no new wire format, no app-side special-casing.
- **Mismatch safety [B11]:** wrong-accessory and mono-TS (ring shorted)
  cases must produce bounded, non-destructive behavior, with a settings hint
  on suspected mismatch.
- Effort: L (PCB rework acknowledged [R7]). Exit: physical validation on the
  bench.

## Tasks

### PCB rework (`hardware/kicad/main_board.py`)

- [ ] Cut the `ENC_SW` net from A2 (`main_board.py:106`) — the encoder push
      switch is never read in firmware (`loopy_pedal.ino:58`); leave every
      other pad→signal mapping untouched (pinmap is user-verified [R7])
- [ ] Add a stereo TRS jack footprint + nets: sleeve → GND; tip/ring into a
      resistor-ladder network feeding **A2 only**, powered ratiometrically
      from VCC so ADC windows track supply
- [ ] Design the ladder so all states occupy distinguishable, guard-banded
      ADC windows on one pin: FS-6 open / tip / ring / tip+ring (four
      discrete levels) vs. a continuous expression-wiper range vs.
      mono-TS-inserted (ring shorted to sleeve) vs. nothing plugged.
      Document the window table in the hardware docs
- [ ] Regenerate board outputs; DRC clean; update
      `hardware/loopy_pedal_pcb_design.md`,
      `hardware/loopy_pedal_pcb_tht_plan.md`, and
      `hardware/loopy_pedal_shopping_list.md` (jack + ladder resistor values)
- [ ] If bench testing shows the single-pin ladder cannot reliably separate
      expression from FS-6 states, fall back to the listed alternatives
      (drop DIN MIDI IN on D0 to free a pin, or I/O expander / respin) —
      **stop and relabel the child issue `plan-gate` before pursuing a
      respin**

### Firmware (`firmware/loopy_pedal/`)

- [ ] ADC sampling on A2 with filtering + hysteresis; extract the ladder
      decode into a host-compilable C unit so decode logic gets coverage in
      the `firmware/test/` runner (window classification, hysteresis at
      window edges)
- [ ] **Expression mode:** scale wiper to absolute CC 0–127; deadband + rate
      limit so a resting pedal never spams; part 7's smoothing/LO-HI ranges
      handle the rest app-side
- [ ] **FS-6 mode:** tip and ring emit two distinct discrete on/off CCs
      (0/127) matching part 7's threshold trigger shape [A10]
- [ ] Choose CC numbers outside the pedal's protocol-reserved traffic (note
      range + relative encoder CC) so part 7's learn hygiene [B8] does not
      ignore them; document them in the firmware protocol doc
- [ ] **Jack-type config (expression vs FS-6)** as a firmware setting,
      persisted on the pedal (EEPROM) and settable from the app — transport
      rides the SysEx-capable inbound seam established for version discovery
      (#331 / part 5); default documented
- [ ] **Mismatch safety [B11]:** wrong accessory for the configured mode and
      mono-TS insertion produce bounded, non-destructive behavior (clamped or
      suppressed CCs — never a value storm, never a stuck momentary);
      firmware reports a suspected-mismatch flag the app can surface
- [ ] Keep `bash firmware/test/run_tests.sh` green (both protocol copies —
      the CI diff-gate from part 5 still applies)

### App settings surface

- [ ] Settings row for pedal jack type (expression / FS-6) beside the
      existing pedal settings; mismatch hint shown when firmware reports a
      suspected mismatch [B11]; l10n in both ARBs + semantics + widget tests

### Docs + validation

- [ ] Hardware jack doc (per the epic's Documentation Plan): ladder window
      table, CC assignments, jack-type config, mismatch behavior
- [ ] Physical validation checklist entries (#203 pattern) covering the four
      bench steps in the success criteria
- [ ] Child issue: `blocked-verify`, dependent on — not gating — the epic's
      close

## Success Criteria

```success-criteria
GOAL: A stereo TRS jack on the pedal drives part 7's expression and discrete-CC triggers via a single-pin resistor-ladder decode on repurposed A2, with safe behavior for every wrong-plug case.

SUCCESS CRITERIA:
- Expression pedal plugged, jack type = expression: full sweep reaches LO..HI on the mapped target | verify: manual bench step 1) expression pedal sweeps LO..HI
- FS-6 plugged, jack type = FS-6: tip and ring each fire their own discrete trigger | verify: manual bench step 2) FS-6 fires both discrete triggers
- Flipping the jack-type setting in the app swaps decode behavior without reflashing | verify: manual bench step 3) jack-type switch swaps behavior
- Mono TS plug degrades to a single working switch, bounded and non-destructive, mismatch hint shown [B11] | verify: manual bench step 4) mono TS degrades to single switch
- Firmware protocol contract tests stay green in both trees after firmware changes | verify: bash firmware/test/run_tests.sh
- App settings row (jack type + mismatch hint) covered by widget tests | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal

NON-GOALS:
- CC→target mapping, learn UI, smoothing, LO/HI ranges — part 7 owns all app-side consumption; this part only produces CCs
- Pedal button bindings / momentary semantics — part 6
- Pedal wire-protocol v3 mode field + version discovery — part 5 (this part only rides its SysEx seam for config)
- Gating the epic close — the epic closes on software-only criteria; this child issue is blocked-verify and lands when the bench says so
- Pickup/catch takeover (jump-on-first-move stands, per part 7 [B9])
- Reading the encoder push switch (the cut ENC_SW net stays unused)

VERIFICATION COMMAND: bash firmware/test/run_tests.sh
(automated gate only — final acceptance is the 4-step manual bench checklist above; the part is blocked-verify)
```

## Notes

- **Do not "fix" the pinmap.** `main_board.py`'s pad→signal map is correct
  and user-verified; RAW is at the USB end. Review agents have repeatedly
  false-flagged it as mirrored — reject that finding if it resurfaces.
- **No ffigen here.** This part touches firmware + PCB + app settings UI,
  not the engine FFI surface. If a task somehow grows a native engine API
  change, that requires ffigen regen + `dart format` (known whole-file churn
  gotcha) — but expect none.
- **cspell + semantic PR title before opening the PR:** the epic mandates
  checking the cspell dictionary (stomp/plog/FS-6/TRS vocabulary — this part
  likely adds wiper/ladder/ratiometric terms) and the semantic-PR-title rule
  up front, not after CI fails.
- **Stacked-PR squash landmines:** part 7 must merge first; child branches
  rebase after the parent squashes, or CI silently goes absent on stale
  merge-refs. Also: git TEXT-merges STEP/DXF — if the PCB rework regenerates
  any CAD outputs, never let git auto-merge them; regenerate from the
  generator instead.
- **Goldens:** screenshot goldens are author-machine-only; the settings row
  is unlikely to touch golden'd screens, but if it does, regen + eyeball on
  the author machine.
- **Bench-first mindset [R7]:** the ladder direction is preferred, not
  proven. Breadboard the ladder against a real expression pedal and a real
  FS-6 before committing the board respin; the alternatives (drop DIN MIDI
  IN D0, I/O expander) are the pre-approved escape hatches.
