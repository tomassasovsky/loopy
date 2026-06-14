---
title: "feat: PSOLA octaver mode (octaver part 4)"
type: feat
date: 2026-06-14
---

## feat: PSOLA octaver mode — Extensive (part 4 of 5)

> Part 4 of the formant-preserving octaver split
> ([umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md)). Implements
> the **PSOLA** algorithm behind `mode ≥ 0.5`, replacing the part-3 dry-passthrough
> stub. PSOLA gives the lowest latency and the most natural result on **solo
> voice**; it degrades predictably on polyphonic/transient input, with a graceful
> unvoiced/silent fallback.

## Overview

Implement `le_psola_tick` (time-domain pitch-synchronous overlap-add) and wire it
into `fx_octaver` in place of the part-3 stub. Because grains are repositioned but
**not resampled**, the grain's spectral shape — the formants — is preserved while
the epoch repetition rate changes the pitch. Mode-switch testing now covers both
directions.

## Problem Statement / Motivation

The phase vocoder (part 3) adds ~21 ms latency — felt on the live-monitoring path.
PSOLA adds only ~one pitch period, making it the better choice for a performer
monitoring themselves. It is the selectable alternative the user asked for.

## Proposed Solution

### `le_psola_tick` (engine.c)

Uses the same `delay[slot][chan]` input FIFO and the `oct[slot][chan]` PSOLA
fields already declared in part 3 (`period`, `voiced`, `in_epoch`, `out_epoch`)
and the shared `out` OLA accumulator.

1. **Pitch detection — YIN, not plain autocorrelation (refined).** Use the
   **YIN** difference function with cumulative-mean normalization over the FIFO,
   searching lags for the vocal range ~60–1000 Hz (at 48 kHz, lags ~48–800
   samples). Pick the **first** normalized-difference minimum below an absolute
   threshold (~**0.15**), then **parabolic-interpolate** around it for a
   sub-sample `period`. Rationale: plain ACF peak-picking is prone to **octave
   errors** (a multiple/submultiple of the true period); wrong grain spacing
   wrecks both pitch and formants, so YIN's octave robustness is worth its modest
   extra cost. Voicing confidence `= 1 − d'(τ)` at the chosen lag (1 = perfectly
   periodic).
2. **Uniform pitch-synchronous marks — no glottal-closure detection (refined).**
   Place analysis grains at **uniform** spacing of `period` samples (Hann,
   length `2·period`); do **not** attempt true GCI/epoch marking (fragile, and
   speech-synthesis-grade fidelity is unnecessary for an effect). Emit synthesis
   grains spaced `period / ratio` (pitch up → closer); grains are copied
   **without resampling**, so the grain's spectral shape — the formants — stays
   fixed. Overlap-add into `out`. `ratio` from `sm_shift` as in part 3.
3. **Fallback contract (D4), with hysteresis + silence floor (refined):**
   - **Silence floor**: if the frame RMS is below a small floor → output silence;
     do **not** run YIN on the noise floor (avoids spurious "pitch" on hiss).
   - **Unvoiced** (`voiced < thresh`, polyphonic, or transient with no clear
     minimum) → return the **delay-matched dry** (no grain buzz). Polyphonic input
     reliably yields low YIN confidence → unvoiced path; documented "solo voice"
     expectation (UI hint + help text).
   - **Hysteresis**: smooth `voiced` with a one-pole and apply a **dead-band**
     around `thresh` (separate enter/exit levels) so a borderline signal does not
     flap voiced↔unvoiced every frame (which would chatter dry↔wet).

> **Latency caveat (refined).** PSOLA latency ≈ one grain ≈ `2·period`. For
> typical voice (100–250 Hz) that is ~8–20 ms — comfortably under PV. But at the
> bottom of the range (~60 Hz, period ≈ 800) it approaches ~33 ms, near PV. Cap
> the **reported** latency (part 5) and the dry-delay length at a sane max
> (e.g. the latency for ~80 Hz) so a brief sub-bass excursion does not yank the
> dry-delay; `le_octaver_latency` returns this clamped value.

### `fx_octaver` wiring

Replace the part-3 stub call so `cur_mode == 1` dispatches to `le_psola_tick`.
`le_octaver_latency` returns PSOLA's latency (~`period`, clamped) so the
**dry-delay (D2)** is re-matched on a mode switch — the part-3 gain-dip already
brackets the latency-length change, so the mix never combs across the switch.

> No new state, no new allocation, no struct/ABI change — part 3 already declared
> the PSOLA fields and the full `le_octaver_state`. PSOLA needs no FFT (cheaper
> than PV — another reason it suits the live path).

## Dependencies

- **Part 3** (the rewritten `fx_octaver`, `le_octaver_state`, the gain-dip
  mode-switch, dry-delay machinery, and the `le_psola_tick` stub it replaces).

## Implementation Order

1. `engine.c`: implement `le_psola_tick` (autocorrelation pitch detect; voiced /
   unvoiced / silence branches; grain OLA; dry fallback).
2. `engine.c`: point the `cur_mode == 1` branch in `fx_octaver` at the real tick;
   make `le_octaver_latency` return the PSOLA latency.
3. Tests below; **register each in `main()`**.
4. Gates: native `ALL PASSED`; `flutter build windows --debug`.

## Acceptance Criteria

- [ ] A voiced (solo-voice-like) input in PSOLA mode shifts pitch with the
      spectral **centroid/formant preserved** (like PV, lower latency).
- [ ] **No octave error**: the detector reports a `period` within tolerance of
      the true period for a clean tone across the vocal range (YIN guard) — no
      half/double-period selection.
- [ ] **No voiced↔unvoiced chatter**: a signal sitting near the voicing threshold
      does not flap dry↔wet every frame (hysteresis dead-band).
- [ ] **Silence** in → silence out (no buzz).
- [ ] **Unvoiced/noise** in → delay-matched **dry** passthrough (no artifacts)
      (D4).
- [ ] **Polyphonic** input degrades to the unvoiced path rather than glitching
      (documented).
- [ ] **Mono coherence**: `l == r` in → `l == r` out in PSOLA mode (D5).
- [ ] **Mode switch** PV↔PSOLA (both directions) mid-playback is click-bounded
      (gain-dip, D1); the dry-delay re-matches so `mix = 0.5` stays comb-free
      across the switch (D2).
- [ ] Gates green: native `ALL PASSED`, Windows debug build compiles.

## Testing

> Same harness reality as part 3 (B3): CHECK/printf, `main()` registration, signal
> analysis — no ASan/alloc counters.

- **`test_octaver_psola_voice_and_fallback`** — voiced input shifts (dominant-bin
  check); silence → silence; noise/unvoiced → dry (D4).
- **`test_octaver_psola_pitch_detect`** — YIN reports the true period (within
  tolerance) for clean tones across 80–400 Hz; **no octave error**; borderline-
  voicing input does not chatter (hysteresis).
- **`test_octaver_mono_coherent`** — extend to assert `l == r` for the PSOLA leg
  (D5).
- **`test_octaver_mode_switch_no_click`** — toggle `p3` PV→PSOLA and PSOLA→PV
  mid-stream; assert bounded sample-to-sample delta (no discontinuity spike, D1).
- **`test_octaver_mix_no_comb`** — confirm still passes for PSOLA at `mix = 0.5`
  (dry-delay re-matched on switch, D2).

## Dependencies & Risks

- **PSOLA fragility on non-monophonic input (H4)** — bounded by the
  voicing-confidence fallback to dry; the "solo voice" expectation is set in the
  UI hint (part 5) and help text.
- **Pitch-detector cost / correctness** — YIN difference function over the FIFO
  each analysis step; cheaper than PV's FFTs but `O(range²)`-ish, so keep the lag
  search tight (vocal band) and reuse/track the period estimate between epochs.
  YIN is chosen over ACF specifically for **octave-error robustness** — an octave
  error would mis-space grains and corrupt both pitch and formants.
- **Mode-switch correctness** — the part-3 gain-dip must bracket PSOLA↔PV latency
  changes; the both-directions click test is the guard.

## References & Research

- `le_psola_tick` design, D1/D2/D4/D5: [umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md).
- Builds on part 3: [part-3](./2026-06-14-feat-formant-preserving-octaver-part-3-plan.md).
- `fx_octaver` / state: [engine.c:411](../../packages/loopy_engine/src/engine.c),
  `le_octaver_state` ([engine_private.h](../../packages/loopy_engine/src/engine_private.h)).
- Algorithm: TD-PSOLA with autocorrelation voicing detection.
