---
title: "feat: phase-vocoder formant-preserving octaver (octaver part 3)"
type: feat
date: 2026-06-14
---

## feat: phase-vocoder formant-preserving octaver — Extensive (part 3 of 5)

> Part 3 of the formant-preserving octaver split
> ([umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md)). The **bulk
> of the DSP work**: rewrites `fx_octaver` into a buffered, formant-preserving
> **phase vocoder** (the default `mode = PV`). PSOLA (part 4) is stubbed to a
> delay-matched dry passthrough so the `mode` toggle is wired but inert on the
> PSOLA side. After this PR the octaver no longer sounds robotic or chipmunk-like.

## Overview

Replace the granular `fx_octaver` ([engine.c:411](../../packages/loopy_engine/src/engine.c))
with an STFT phase vocoder that preserves formants via a cepstral spectral
envelope (whiten → shift residual → re-apply original envelope). The chain still
calls the effect one sample at a time; internally it buffers input, runs one FFT
frame per hop, and emits a latency-delayed sample. All heavy buffers are
pre-allocated on the control thread — the audio thread never allocates.

## Problem Statement / Motivation

The granular octaver sounds **robotic** (2× grain overlap combs/warbles) and
**chipmunk-like** (resampling shifts formants with pitch). A spectral-envelope
phase vocoder fixes both: it shifts the harmonic structure while holding the
formant envelope in place. See the umbrella for the full diagnosis.

## Proposed Solution

### Constants (engine.c)

```c
#define LE_PV_N      1024            // STFT window (power of two)
#define LE_PV_HOP    256             // 4x overlap (HOP = N/4: the clean-PV minimum)
#define LE_PV_BINS   (LE_PV_N/2 + 1)
#define LE_PV_LIFTER (LE_PV_N/24)    // ~42: cepstral lifter cutoff (see envelope note)
```

`fft.h` (part 1) is `#include`d here; the shared Hann table is initialized with
`LE_PV_N`.

**Window / latency rationale (refined).** Algorithmic latency ≈ `LE_PV_N`
samples (~21 ms @ 48 kHz). This is **not only** a live-monitoring cost: it delays
this lane's effect output relative to the **other lanes in the loop mix**, so a
larger window smears inter-lane timing. That favors the **smaller** window. The
cost of `N = 1024` is frequency resolution: bin width `sr/N ≈ 47 Hz`, and the
cepstrum's lowest resolvable quefrency is `N/2 = 512` samples ≈ **93 Hz** — below
that the pitch peak aliases into the formant envelope and the envelope estimate
degrades (relevant for low male voice / bass). `LE_PV_HOP = N/4` (4× overlap) is
the standard clean-PV minimum; 8× would halve artifacts at 2× the FFT rate, which
the CPU budget (the headline risk) does not justify.

**Tunability.** `N` is a single constant. Default `1024`. If the low-fundamental
formant test (AC below, 100 Hz) fails, bump to `2048` (latency ~43 ms, resolution
~23 Hz, low-f0 floor ~47 Hz) and `LE_PV_LIFTER` scales with it automatically
(`N/24`). Per-lane latency compensation for the resulting inter-lane delay is a
documented follow-up (umbrella §Out of Scope), not part of this PR.

**Formant envelope detail (`LE_PV_LIFTER`).** The cepstral lifter keeps the first
`LE_PV_LIFTER` quefrency coefficients as the spectral envelope. The cutoff must
stay **well below the pitch quefrency** (`period = sr/f0` samples) so the source
(pitch) and filter (formants) separate; `N/24 ≈ 42` resolves ~4–5 formants and
sits safely below the quefrency of any f0 above ~110 Hz. It scales with `N` so
the envelope smoothness in Hz is preserved if `N` changes.

**Tone control (`p1`) stays.** The post-tick one-pole low-pass driven by `p1` is
retained as before — an independent **darkening** preference on the shifted
voice, orthogonal to formant preservation (which lives in the envelope step). It
keeps the existing param's meaning and UI; no change to its semantics.

### State — `le_fx_state` (engine_private.h)

Add the octaver working set as a nested struct, one per slot **per channel**
(`[LE_FX_MAX][2]`). **Define the full struct now** — including the PSOLA fields
part 4 will use — so part 4 needs no struct/ABI change.

```c
typedef struct le_octaver_state {
  // Phase vocoder buffers (calloc'd control-side when the slot becomes OCTAVER)
  float* out;          // synthesis overlap-add accumulator, length LE_PV_N
  float* last_phase;   // [LE_PV_BINS]
  float* sum_phase;    // [LE_PV_BINS]
  int32_t hop_count;   // samples since last frame
  int32_t out_pos;     // read/write phase within `out`
  // PSOLA (part 4; zero-initialized + unused here)
  float   period;
  float   voiced;
  int32_t in_epoch;
  int32_t out_epoch;
  // Shared: param smoothing + mode-switch gain-dip (D1/D2/H3)
  float   sm_shift, sm_tone, sm_mix;
  int32_t cur_mode;    // 0 = PV, 1 = PSOLA
  float   xfade;       // gain-dip envelope during a mode switch (1 = steady)
} le_octaver_state;
```

**N1 — remove dead `grain_phase`**: the granular octaver is fully replaced and
`grain_phase[LE_FX_MAX][2]` has no other consumer. Delete the field and its line
in `le_fx_entry_reset` (engine.c:531). The input ring stays `delay[slot][chan]`
(reused as the PV input FIFO).

### Processor — `fx_octaver` (engine.c)

Signature unchanged. Body: write `x` to the FIFO; smooth params (`sm_*`,
zipper-free per H3); read `mode = p[3] >= 0.5`; on a mode change run the
**gain-dip** (D1, refined: **equal-power cosine** fade, **~15 ms per leg** —
fade-out → reset DSP state + dry-delay length → fade-in; `xfade` is the cosine
envelope masking both the algorithm discontinuity and the latency-length change;
the PSOLA branch returns dry in this PR); call `le_pv_tick` for the wet voice; one-pole tone LP; **delay-matched
dry** read from the FIFO at `head − LE_PV_N` (D2 — for PV the latency is the
compile-time constant `LE_PV_N`, so this is two lines, no runtime dispatch);
return `dry*(1-sm_mix) + xfade*wet*sm_mix`.

**`le_pv_tick`** — runs the frame once per `LE_PV_HOP` samples; returns the next
`out` sample every call (latency `LE_PV_N`):
1. Hann-window the latest `N` FIFO samples; `le_rfft_fwd` → `re/im`.
2. Per bin: `mag`, `phase`; phase-difference vs `last_phase` → **true frequency**.
3. **Formant envelope** `env[k]`: cepstrum of `log(mag)` (`le_rfft_*` on the
   log-magnitude), keep quefrencies `< LE_PV_LIFTER`, exponentiate → smooth
   envelope.
4. **Whiten → shift → re-apply**: `res[k] = mag[k]/env[k]`; target bin
   `j = round(k·ratio)`; `synMag[j] = res[k]·env[j]` (original envelope at the
   **destination** keeps formants fixed); `synFreq[j] = trueFreq[k]·ratio`.
5. Accumulate `sum_phase[j]`; rebuild `re/im`; `le_rfft_inv`; Hann-window;
   **overlap-add** into `out`.
6. FFT scratch (`re[N]`, `im[N]`, log-mag, env, syn buffers) is **stack-local** —
   bounded, no allocation.

`ratio = 2^((sm_shift − 0.5)·48/12)` (±2 octaves, unison at 0.5).

### Allocation / reset / destroy (control thread)

- **`le_fx_prepare_entry`** ([engine.c:2789](../../packages/loopy_engine/src/engine.c)):
  for `LE_FX_OCTAVER`, after the two `delay` rings (`needs_right`), allocate
  `oct[index][chan].out` (`LE_PV_N`), `.last_phase`, `.sum_phase` (`LE_PV_BINS`)
  for `chan ∈ {0,1}` when `NULL`.
  - **N2 — explicit OOM free-order**: this one call can hold up to 8 allocations
    (2 rings + 6 PV buffers). Track a flag per buffer this call allocated. On any
    failure, free **only** the buffers/rings **this call** newly allocated, in
    reverse order, null them, return `LE_ERR_INVALID`. **Never** free a ring or
    buffer the slot already owned from a prior type (mirrors the existing
    `allocated0` pattern at engine.c:2799-2817). Document the free list inline.
- **`le_fx_entry_reset`** ([engine.c:524](../../packages/loopy_engine/src/engine.c)):
  zero the octaver scalars for both channels (`hop_count`, `out_pos`, `period`,
  `voiced`, epochs, `sm_*`, `cur_mode`, `xfade = 1`) and `memset` the three PV
  buffers (per channel) **if allocated**.
  - **N3 — name the RT cost**: this runs on the **audio thread** (SET_*_FX ring
    handlers) and now does a ~16 KB `memset` on a type-change event. That is
    bounded, fires only on a discrete user action (not per-sample), and is
    consistent with the existing reverb clears — but the RT-safety note must say
    so explicitly rather than imply "reads/writes only."
- **`le_lane_reset` / `le_monitor_lane_reset`** (~engine.c:1509/1536) and
  **`le_engine_destroy`** (both lane loops, ~engine.c:2124/2132): `free` the
  three `oct[s][chan]` buffers (both channels), null them, alongside the existing
  `delay[s][...]` frees.
- **Reorder/retype (M1)**: keeping the slot OCTAVER preserves params and does not
  reallocate (the "re-seed defaults only when type changes" guard at
  engine.c:2819 already covers this); retype away frees the octaver buffers;
  retype back reallocates + re-seeds.

## Dependencies

- **Part 1** (`fft.h`) and **Part 2** (4-param model, so `p[3] = mode` exists).

## Implementation Order

1. `engine_private.h`: add full `le_octaver_state` + `oct[LE_FX_MAX][2]`; remove
   `grain_phase` (N1).
2. `engine.c`: `#include "fft.h"`; constants; `le_pv_tick`, `le_octaver_smooth`,
   `le_octaver_handle_mode_switch` (gain-dip; PSOLA branch → dry), `le_octaver_tone`,
   `le_octaver_latency` (returns `LE_PV_N` for PV, ~one period for PSOLA in part 4);
   `le_psola_tick` **stub → delay-matched dry**; rewrite `fx_octaver`.
3. `engine.c`: `le_fx_prepare_entry` allocation + N2 OOM free-order;
   `le_fx_entry_reset` (zero + memset, N3 note); lane/monitor reset + destroy frees.
4. Tests below; **register each in `main()`**.
5. Gates: native `ALL PASSED`; `flutter build windows --debug`.

## Acceptance Criteria

- [ ] A 220 Hz mono sine, octave-up (`shift = 0.75`): output fundamental ≈ 440 Hz
      **and** spectral **centroid** stays near the input's (formant preserved) —
      measurably unlike a naive resample (centroid ≈ doubles).
- [ ] Octave-**down** likewise preserves the envelope; output ≈ 110 Hz.
- [ ] **Low-fundamental gate (window-size guard)**: a **100 Hz** complex tone
      (fundamental + a few harmonics) octave-up preserves the spectral centroid
      within tolerance. If this fails at `N = 1024`, the documented fix is
      `N = 2048` — this test is the trigger for that decision.
- [ ] **Mono coherence**: `l == r` in → `l == r` out (deterministic per channel,
      D5).
- [ ] **No comb at `mix = 0.5`**: broadband input shows no deep periodic notches
      (dry delay-matched, D2).
- [ ] **Zipper-free**: a full-range `shift`/`tone`/`mix` drag has bounded
      sample-to-sample deltas (no clicks, H3).
- [ ] **Lifecycle (M1)**: reorder/retype/remove of an octaver slot under audio —
      process survives, output stays sane, and a different effect later landing on
      that slot index is unaffected.
- [ ] No `grain_phase` remains (N1).
- [ ] OOM on any of the 8 allocations leaves the slot un-typed and leak-free
      (N2) — verified by an injected-failure unit test if feasible, else code
      review against the documented free list.
- [ ] Gates green: native `ALL PASSED`, Windows debug build compiles.

## Testing

> **B3 — harness reality**: `test_engine_core.c` is a `CHECK()`/`printf` runner
> with a hand-maintained `main()` call list and **no** ASan / malloc-interposer.
> Tests assert via signal analysis, process survival, and output sanity — **not**
> instrumented allocation/leak counters. Each new test is added to `main()`.

- **`test_octaver_pv_shifts_pitch_preserves_formant`** — sine in; assert dominant
  output bin ≈ `ratio·f` **and** spectral centroid ≈ input centroid, up & down.
- **`test_octaver_pv_low_fundamental`** — 100 Hz complex tone, octave-up; assert
  centroid preserved (the `N = 1024` vs `2048` window-size gate).
- **`test_octaver_mono_coherent`** — `l == r` in → `l == r` out (PV) (D5).
- **`test_octaver_mix_no_comb`** — broadband at `mix = 0.5`; no deep comb notch
  (D2).
- **`test_octaver_param_smoothing_no_zipper`** — sweep `shift`/`mix`; bounded
  deltas (H3).
- **`test_octaver_lifecycle`** — reorder/retype/remove under processing; assert
  survival + output sanity + the existing retained-ring reorder pattern
  (cf. `test_fx_stereo_ring_retained_across_type_reorder`). **No** UAF/leak
  instrumentation is claimed (B3).
- **No-alloc invariant (B3)** — stated as a **documented invariant** enforced by
  code review (control-thread allocation only); if a counting allocator is added
  to the test TU later it can be asserted, but this PR does not claim it.
- Existing FX tests stay green (mono inputs, no `p[3]` read).

## Dependencies & Risks

- **Real-time CPU** is the headline risk: one `N`-FFT plus two cepstrum `N`-FFTs
  per hop per channel per octaver. Bounded by `LE_FX_MAX` octavers × active
  lanes/monitors; `N = 1024` amortized over 256 samples. Measure against the
  audio deadline at max chain depth before merge.
- **Cepstral envelope correctness** — verify the whiten→shift→re-apply preserves
  the centroid (the formant test is the guard).
- **8-allocation OOM path** (N2) is where a leak/double-free hides — the explicit
  free list is the mitigation.
- **Audio-thread `memset` on type-change** (N3) — bounded, named in the RT note.

## References & Research

- `fx_octaver` / chain: [engine.c:411](../../packages/loopy_engine/src/engine.c),
  [engine.c:622](../../packages/loopy_engine/src/engine.c).
- State: `le_fx_state` ([engine_private.h:80](../../packages/loopy_engine/src/engine_private.h)).
- Alloc/reset/destroy: `le_fx_prepare_entry` (2789), `le_fx_entry_reset` (524),
  lane/monitor reset (1509/1536), destroy loops (2124/2132).
- FFT primitive: [part 1](./2026-06-14-feat-formant-preserving-octaver-part-1-plan.md).
- 4-param model: [part 2](./2026-06-14-feat-formant-preserving-octaver-part-2-plan.md).
- Decisions D1/D2/D5, edge cases, CPU note: [umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md).
