---
title: "feat(console): real chromatic tuner in the Tuner rail destination"
type: feat
date: 2026-08-07
issue: 482
---

## Overview

The Tuner rail destination exists and is a stub. This plan makes it real, built
to the `TUNER / tuner` and `TUNER / tuner-mic` screens in `segno-ui.pen`.

Two halves that meet at one struct: the engine detects pitch on one selected
hardware input and publishes it on `le_snapshot`; the console face reads it
through `LooperState` and draws a needle.

The work is smaller than #482 estimated, for one reason worth stating up
front: **the octaver's YIN constants do not need to move.** See
*The detection band* below — that reframing is the difference between a
risky RT-budget change and an additive one.

## What was blocking, and why it no longer is

#482 has been parked at `stage:brainstorm` since 2026-08-04, blocked on #442
answering where the tuner lives. That question is answered twice over:

- **#442 decision D6** — rail destination, not a full-screen takeover. The
  tray is already near-fullscreen, so Sheeran's takeover buys nothing.
- **The console IA (#498)** shipped the rail with `Tuner` as one of its eight
  entries. `SettingsTrayDestination.tuner` and `TunerTrayPanel` are on master
  today; `tuner_tray_panel.dart` carries the stub message and its own note
  that it should move to `lib/tuner/` once there is a tuner behind it.

#442's remaining parts (3–6, 8, 9) are about racks, stage tabs and the pedal's
Custom mode. None of them touch this face. The block is stale and this plan
does not wait on them.

## What the design settles

Four of the five questions #482 left open are answered by the two screens, not
by this plan. Reading them off the geometry:

| Question | What the design shows |
|---|---|
| Which signal it taps | Tabs `guitar` \| `mic` — **named hardware inputs**, the `InputsCubit` names already read through `l10n.inputName`. Not a lane, not a stage. |
| Does tuning mute | No mute control, no warning banner, and the stage plays behind the tray with `REC` lit. **Tuning does not mute.** |
| Strobe or needle | **Needle.** A full-width track (1700×10, `#26262a`) with a fixed centre tick (1×22, `#3a3a40`) and a moving indicator (5×17, `#30a46c`). |
| Reference pitch | No control on either screen → **fixed A=440** in v1. Confirmed by the mic screen's own arithmetic, below. |

The rest of the face: the title `Tuner` (fs20, `#f3f4f7`), the tab strip, the
note letter centred at fs67 `#f3f4f7`, the track, and a readout at fs16
`#9a9aa2` reading `+4 cents · 442.1 Hz` / `−9 cents · 163.9 Hz`.

Note the readout's separator is a middle dot (U+00B7) with spaces either side,
and its minus is U+2212, not a hyphen.

### A defect in the design, to fix before building to it

`TUNER / tuner-mic` reads **E · −9 cents · 163.9 Hz**. At A=440, E3 is
164.81 Hz and −9 cents is 163.95 Hz. That is exact, and it is what pins the
reference pitch at 440.

`TUNER / tuner` reads **A · +4 cents · 442.1 Hz**. At A=440, +4 cents is
441.0 Hz, and 442.1 Hz is +8 cents. The pair cannot both be right. Its sibling
screen is self-consistent, so this is a slip in the guitar screen, not evidence
of a 442 reference.

It needs a pen fix before the face is built to it — otherwise the first
golden encodes an impossible reading. Which number moves is an open question
below.

### What the design does not draw

The build decides these, and they should be written back into the pen
afterwards:

- **Sharps and flats.** Both screens show natural notes. Nothing says whether
  F♯ reads `F♯`, `Gb`, or `F#`.
- **No device / no signal / unnamed input.** All three are reachable and none
  is drawn. An unnamed input already has an answer — `l10n.inputName` falls
  back to the socket number — but silence on an armed input does not.
- **Octave.** The note letter carries no octave number. E3 and E2 read the
  same. That is normal for a tuner and probably deliberate.

## The engine half

### The detection band — why the octaver's constants stay put

`le_psola_detect()` (`engine_fx.c:282`) searches `sr/1000` … `sr/60`, capped at
`LE_PSOLA_MAXLAG` (800), over `LE_PSOLA_WIN` (1600) samples. Bass low B is
30.9 Hz, well under that floor — which is what #482 recorded as "the YIN band
needs widening".

Widening it in place is the wrong move. At 48 kHz a 30.9 Hz floor is
maxlag ≈ 1553, the window must be ≥ 2·maxlag (~3100), and YIN is
O(maxlag × integ) — roughly 2.4M multiply-adds per detection, on the audio
thread, in a detector the octaver calls per grain. That trades a tuner for a
dropout risk in an unrelated effect.

**Decimate instead — but the band has to become a parameter.**

**[Corrected 2026-08-08, during the build.]** What this section originally
said was wrong, and wrong in the direction that matters. It claimed that
handing `le_psola_detect()` a decimated rate "re-bands it for free". The
function derives *both* ends of its search from `sr` (`sr/1000` … `sr/60`),
so decimating rescales the whole band with it and the floor stays at 60 Hz
whatever rate it is handed. Low B was never reachable that way.

What decimation actually buys is **cost, not reach**. YIN is
O(lags × integration), so the same 30 Hz floor is 200 lags at 6 kHz against
1600 at 48 kHz. To reach the floor at all, the band must be explicit:

- `le_psola_detect_band(x, n, sr, min_hz, max_hz, …)` carries the search, and
  `le_psola_detect()` becomes that function at `(60, 1000)` — so the octaver's
  lags are bit-identical and `LE_PSOLA_MAXLAG` / `_WIN` / `_THRESH` still
  never move.
- The tuner calls it at `(30, 1000)` over a boxcar-decimated signal. A boxcar
  of exactly the decimation factor nulls at the decimated rate — which is
  where aliasing would fold in from — so it is its own anti-alias filter.

**Decimation also costs resolution, and that needs a second pass.** A
fraction-of-a-decimated-sample error is sub-cent at low B (a 200-sample
period) but **~6 cents at high E** (an 18-sample one), which is a tuner nobody
trusts. So the coarse decimated pass decides the octave, and a narrow
plain-difference search at the **device** rate around that lag recovers the
resolution. It walks ~2× the decimation factor in lags, so it costs a fraction
of the coarse pass, and it declines to run when the lag is too long for its
ring — which is the low end, where the coarse answer is already sub-cent.

Measured end to end after this: **within 0.02 cents from 30.87 Hz to
329.63 Hz**.

Two smaller corrections while here: parabolic interpolation was **already** in
`le_psola_detect`, so the claim that it had to be added was also wrong; and
the cadence is one pass per `LE_TUNER_HOP` (256) decimated samples, ~43 ms.

### Tap point

Alongside where `a_in_rms_bits` is written (`engine_process.c:4064`), but
per-channel rather than summed. That point is pre-FX and pre-lane by
construction, which is what a tuner wants: the player is tuning the
instrument, not the patch.

### API surface

One command and three snapshot fields.

```c
LE_CMD_SET_TUNER_INPUT      /* arg_i = hardware input channel; -1 = off */
le_engine_set_tuner_input(le_engine*, int32_t input);
```

Gating is not an optimization, it is the contract: detection runs only while
an input is armed, so a console that never opens the Tuner face pays nothing.

Appended at the **end** of `le_snapshot`, which documents trailing placement
as the way to preserve every existing field's offset for readers built against
the old layout:

```c
float   tuner_hz;          /* detected fundamental; 0 = no pitch this frame */
float   tuner_confidence;  /* 0..1, from YIN's voiced score */
int32_t tuner_input;       /* echo of the armed channel; -1 = not armed */
```

`tuner_input` earns its place: without it the face cannot tell *armed and
silent* from *not armed yet*, and those need different words on screen.

## The Dart half

- **`EngineSnapshot`** gains `tunerHz`, `tunerConfidence`, `tunerInput`
  (`engine_snapshot.dart`), mapped in `fromNative`. `MockAudioEngine` gains
  them too, so a test can drive a pitch without native.
- **`LooperState`** projects them. The repository already polls at ~60 Hz
  (`looper_repository.dart:365`), which is well above what a needle needs — the
  detector's own ~25 ms cadence is the real rate, and the poll just resamples it.
- **`lib/tuner/`** — a new feature folder, as `tuner_tray_panel.dart`'s own doc
  comment anticipates. `TunerCubit` holds the selected input, arms on show and
  disarms on hide, and holds the last confident reading through a short decay
  so the needle does not snap to nothing between picks.
- **Hz → note is pure and unit-testable**, and should be tested against the
  design's own numbers: `n = round(12·log₂(f/440))`, cents =
  `1200·log₂(f/f_n)`. 163.9 Hz must come back E, −9 cents.

## The face

`lib/tuner/view/tuner_tray_panel.dart` replaces the stub, composing from
`console_surface.dart` and `PillTabs` (`lib/common/pill_tabs.dart`) — the same
tab idiom every other domain uses. It draws no chrome of its own.

The needle's horizontal position maps cents to offset. The design's indicator
sits 68px right of a centre tick on a 1700-wide track for +4 cents; that ratio
is not a round number, so the build sets a sane full-scale (±50 cents across
the track) and writes the resulting geometry back into the pen rather than
reverse-engineering the mockup's pixel.

## Verification

- `flutter test` (absolute path per CLAUDE.md), `dart analyze`, `bloc lint`.
- `bash packages/segno_engine/src/test/run_native_tests.sh` — the native suite
  gains a tuner case: synthesize a sine at a known frequency, arm the input,
  assert `tuner_hz` inside a cent or two. Low B (30.9 Hz) and the 1 kHz ceiling
  are the two that matter.
- An octaver regression is **not** needed and its absence is the point: no
  shared constant moves.
- Goldens under `test/screenshots/` — author-machine only, regenerate and
  eyeball.

## Non-goals

- Muting, and any control for it. The design says tuning does not mute.
- Strobe display.
- Guitar/bass string presets, or any non-chromatic mode.
- Driving the tuner from the pedal.
- Mirroring the tuner onto the 7" readout (`STAGE / readout`).
- Adjustable reference pitch — pending the question below.

## Open questions — `autonomy:plan-gate`

1. **Reference pitch.** The design implies fixed A=440 and the mic screen's
   arithmetic confirms it. Ship fixed, or add a reference-pitch control? A
   control needs a pen screen first; there is nowhere on the face for it today.
2. **Detection floor.** Decimation makes low B (30.9 Hz) about as cheap as low
   E, so the recommendation is low B and no reason to compromise. Confirm.
3. **Arming lifetime.** Arm only while the Tuner face is showing (cheapest,
   and the tuner is silent-by-default), or stay armed once visited so
   re-opening is instant? Recommendation: arm on show, disarm on hide.
4. **The pen's guitar-screen slip.** Fix the Hz to `441.0` (keeping +4 cents),
   or fix the cents to `+8` (keeping 442.1 Hz)? Either is one number; the
   first keeps the needle near centre, which is what that screen is showing.
5. **Sharps.** `F♯` / `Gb` / `F#` — undrawn. Recommendation: `F♯` (U+266F),
   matching the readout's existing use of a real U+2212 minus.
