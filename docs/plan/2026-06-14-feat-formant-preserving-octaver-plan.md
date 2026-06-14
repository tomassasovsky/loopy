---
title: "feat: formant-preserving octaver (phase vocoder + PSOLA)"
type: feat
date: 2026-06-14
---

> **Note:** This plan has been split into parts for independent review/merge. See
> the `-part-N` files in this directory. This file is retained as the **umbrella**
> (shared design, decisions D1–D6, edge cases) the parts reference:
> - [part 1 — `fft.h` primitive](./2026-06-14-feat-formant-preserving-octaver-part-1-plan.md)
> - [part 2 — `LE_FX_PARAMS` 3→4 plumbing](./2026-06-14-feat-formant-preserving-octaver-part-2-plan.md)
> - [part 3 — phase vocoder algorithm](./2026-06-14-feat-formant-preserving-octaver-part-3-plan.md)
> - [part 4 — PSOLA algorithm](./2026-06-14-feat-formant-preserving-octaver-part-4-plan.md)
> - [part 5 — latency exposure + UI hint](./2026-06-14-feat-formant-preserving-octaver-part-5-plan.md)
>
> Technical-review fixes (B1: widen **all** `defaultParams`; B2: real `fromJson`
> pad/truncate with per-type defaults; B3: tests are CHECK/printf + `main()`
> registration, no ASan/alloc-interposer claims; B4: latency snapshot field is a
> real ABI/ffigen change; N1: drop dead `grain_phase`; N2: explicit OOM
> free-order; N3: name the audio-thread `memset`; N4: l10n template ordering) are
> folded into the parts where they land.

## feat: formant-preserving octaver (phase vocoder + PSOLA) — Extensive (umbrella)

> No source brainstorm; design settled in discussion. Native-only DSP rewrite of
> one effect (`LE_FX_OCTAVER`) in the shared FX chain
> ([packages/loopy_engine/src/engine.c](../../packages/loopy_engine/src/engine.c)),
> used by **both** track lanes and monitor lanes. Builds on the full-stereo FX
> chain ([docs/plan/2026-06-14-fix-stereo-effects-chain-plan.md](./2026-06-14-fix-stereo-effects-chain-plan.md))
> — the per-channel `le_fx_state` (`[LE_FX_MAX][2]`) it introduced is the
> substrate this rewrite extends. A user-flow analysis ran against this design;
> its gaps are folded into §Edge Cases and §Acceptance Criteria.

## Overview

The octaver is a time-domain granular pitch shifter that sounds **robotic** (2×
grain overlap → comb/warble) and **chipmunk-like** (no formant correction — any
upward shift drags vocal formants up with the pitch). Replace it with a
**formant-preserving** shifter offering two selectable algorithms:

- **Phase vocoder (default)** — STFT-based, robust on any input (voice, chords,
  full mixes). Formants preserved by extracting the spectral envelope (cepstral
  liftering), shifting only the whitened residual, then re-applying the original
  envelope. ~21 ms latency at 48 kHz (N = 1024, 4× overlap).
- **PSOLA (selectable)** — time-domain pitch-synchronous overlap-add. Lowest
  latency, most natural on **solo voice**; degrades predictably on
  polyphonic/transient input, with a graceful unvoiced/silent fallback.

A new normalized parameter `p3 = mode` (`< 0.5` → phase vocoder, `≥ 0.5` →
PSOLA) selects the algorithm. This requires bumping the global param width
`LE_FX_PARAMS` / `kTrackEffectParams` from **3 → 4**.

## Problem Statement / Motivation

`fx_octaver` ([engine.c:411](../../packages/loopy_engine/src/engine.c)) reads two
taps a half-grain apart from a delay ring, Hann-crossfaded. Two defects:

1. **Robotic** — only 2× overlap. The two simultaneously-summed taps sit ~15 ms
   apart, so they comb-filter; the grain re-triggers at ~16 Hz for an octave
   shift. That buzzy warble is the "robotic" character.
2. **Chipmunk** — the read rate resamples the signal, so **formants shift with
   pitch**. There is no spectral-envelope correction, so an up-shift sounds like
   Alvin & the Chipmunks; a down-shift sounds like a monster.

Neither is fixable by tuning the granular method — formant preservation requires
either a spectral-envelope (phase vocoder) or pitch-synchronous (PSOLA)
approach. The user chose **both, selectable** (phase vocoder default, PSOLA
toggle).

## Proposed Solution

Rewrite `fx_octaver` into a **buffered** per-channel processor. The chain still
calls it one sample at a time; internally it accumulates input into a FIFO,
runs a block every hop, and emits a latency-delayed output sample. All heavy
buffers are **pre-allocated on the control thread** (audio thread never
allocates). A new header-only `fft.h` provides the FFT (no new translation unit
→ no CMake/podspec/test-list churn).

### Recorded design decisions (resolve the flow-analysis required decisions)

| # | Decision | Choice |
|---|----------|--------|
| D1 | **Mode toggle PV↔PSOLA** (not a type-change, so no reset fires) | `mode` is a **discrete 2-division** UI control (no threshold chatter). On a change, mask the discontinuity with a short **equal-power cosine gain dip** (~15 ms per leg: fade-out → switch state + dry-delay length → fade-in). Mode is a setup choice, rarely toggled live, so the brief dip is the right cost. (Alt: equal-power crossfade running **both** engines — rejected for 2× CPU + double latency-fill; see §Out of Scope.) |
| D2 | **Dry/wet comb** (delayed wet vs. un-delayed dry at `mix < 1`) | The dry tap is **delay-matched** to the *active mode's* latency by reading the input FIFO at `head − latency` (no extra buffer). The dry-delay length is part of the state re-set inside the D1 fade window, so a mode switch never combs. |
| D3 | **Live-monitor latency** (octaver runs on monitor lanes; unmodeled today) | Engine **exposes** the active octaver's added latency in the snapshot; UI surfaces a hint ("Phase Vocoder adds ~21 ms — use PSOLA for live monitoring"). Record-offset compensation for an octaver in the monitored-**and**-recorded path is documented; full auto-compensation is a **follow-up** (see §Out of Scope) to bound this PR. |
| D4 | **PSOLA on unvoiced/silent/polyphonic** | **YIN** pitch detector (octave-robust) with a **voicing confidence**; below threshold → pass the **delay-matched dry** (no grain buzz); RMS **silence floor** → silence-out; **hysteresis** dead-band so borderline input doesn't flap dry↔wet; polyphonic input degrades predictably (documented "solo voice"). See [part 4](./2026-06-14-feat-formant-preserving-octaver-part-4-plan.md). |
| D5 | **Mono coherence** (`l == r` in → `l == r` out) | Per-channel instances are **fully deterministic** (no randomness; identical init state + identical params), so a mono source yields identical L/R output. No cross-channel coupling, so genuine stereo still works. Verified by test. |
| D6 | **Persistence** (old 3-param saved chains) | `TrackEffect.fromJson` **pads/truncates** `params` to `kTrackEffectParams`, defaulting a missing `p3` to `0.0` (PV). Tested with an old-format JSON fixture. |

### New FFT — `fft.h` (header-only, static)

```c
// packages/loopy_engine/src/fft.h — included by engine.c only.
// In-place iterative radix-2 complex FFT (power-of-two), plus real-input helpers.
static void le_fft(float* re, float* im, int n, int inverse);     // n power of two
static void le_rfft_fwd(const float* x, float* re, float* im, int n); // real -> half-spectrum
static void le_rfft_inv(const float* re, const float* im, float* y, int n);
```

- No malloc — caller passes scratch. Pure C11, portable (Clang/GCC/MSVC). A
  shared file-scope **Hann window table** (size `LE_PV_N`, built once under a
  guarded init) is read-only, not per-instance.
- **Build impact: none** — header-only, `#include "fft.h"` in engine.c. CMake
  source list, podspec glob, and the test build's explicit file list are
  untouched.

### Constants

```c
#define LE_PV_N        1024        // STFT window (power of two)
#define LE_PV_HOP      256         // 4x overlap; analysis = synthesis hop
#define LE_PV_BINS     (LE_PV_N/2 + 1)
#define LE_PV_LIFTER   (LE_PV_N/24) // ~42: cepstral lifter, scales with N (see part 3)
// Latency = LE_PV_N samples (~21 ms @ 48 kHz). PSOLA latency ~= one grain (clamped).
```

> Refined sizing/latency rationale, the low-fundamental (`N=1024` vs `2048`)
> trade-off, and the `LE_PV_LIFTER = N/24` relationship are authoritative in
> [part 3](./2026-06-14-feat-formant-preserving-octaver-part-3-plan.md).

`N`/`HOP` are documented as the latency/quality knob. `cap` (the 1 s ring) is
unchanged and dwarfs `N`, so the FIFO reuse is safe.

### Per-channel state — `le_fx_state` (engine_private.h)

Group the octaver's working set into a nested struct to keep `le_fx_state`
readable, one per slot **per channel** (`[LE_FX_MAX][2]`), preserving the stereo
substrate:

```c
typedef struct le_octaver_state {
  // Phase vocoder (pointers calloc'd control-side when the slot becomes OCTAVER)
  float* out;          // synthesis overlap-add accumulator, length LE_PV_N
  float* last_phase;   // [LE_PV_BINS] previous analysis phase
  float* sum_phase;    // [LE_PV_BINS] accumulated synthesis phase
  int32_t hop_count;   // samples since last frame
  int32_t out_pos;     // read/write phase within `out`
  // PSOLA
  float   period;      // current pitch period estimate (samples), 0 = unvoiced
  float   voiced;      // smoothed voicing confidence 0..1
  int32_t in_epoch;    // last analysis epoch position (FIFO-relative)
  int32_t out_epoch;   // next synthesis epoch position
  // Shared: param smoothing + mode-change fade (D1/D3, zipper-free per H3)
  float   sm_shift, sm_tone, sm_mix; // one-pole-smoothed params
  int32_t cur_mode;    // 0 = PV, 1 = PSOLA (the algorithm currently running)
  float   xfade;       // gain-dip envelope during a mode switch (1 = steady)
} le_octaver_state;
```

```c
typedef struct le_fx_state {
  float svf_ic1[LE_FX_MAX][2];
  float svf_ic2[LE_FX_MAX][2];
  float lfo[LE_FX_MAX][2];
  float* delay[LE_FX_MAX][2];          // octaver REUSES this as its input FIFO
  int32_t delay_pos[LE_FX_MAX][2];
  float fx_lp[LE_FX_MAX][2];
  float grain_phase[LE_FX_MAX][2];     // retained (legacy reset compat; unused by new octaver)
  le_octaver_state oct[LE_FX_MAX][2];  // NEW
  int32_t rev_comb_pos[LE_FX_MAX][LE_REV_COMBS * LE_REV_BANKS];
  float rev_comb_lp[LE_FX_MAX][LE_REV_COMBS * LE_REV_BANKS];
  int32_t rev_ap_pos[LE_FX_MAX][LE_REV_APS * LE_REV_BANKS];
} le_fx_state;
```

The input ring stays `delay[slot][chan]` (already allocated for OCTAVER by
`needs_right`). The dry tap reads it at `head − latency` (D2). FFT scratch
(`re[N]`, `im[N]`, cepstrum buffers) is **stack-local** in the frame function —
bounded, no allocation.

### The processor — `fx_octaver` (engine.c)

Signature unchanged (`fx_octaver(fx, slot, chan, cap, x, p)`), body rewritten:

```c
static float fx_octaver(le_fx_state* fx, int slot, int chan, int cap, float x,
                        const float* p) {
  le_octaver_state* o = &fx->oct[slot][chan];
  float* fifo = fx->delay[slot][chan];
  if (fifo == NULL || cap <= LE_PV_N) return x;        // guard (parity w/ cap<=4)

  // 1. Write dry input to FIFO head; advance.
  const int head = fx->delay_pos[slot][chan];
  fifo[head] = x; /* advance delay_pos with wrap */

  // 2. Smooth params (H3 zipper-free). mode is read raw (discrete).
  le_octaver_smooth(o, p);                              // sm_shift/sm_tone/sm_mix
  const int want_mode = p[3] >= 0.5f ? 1 : 0;
  le_octaver_handle_mode_switch(o, want_mode);          // D1 gain-dip + state/dry-delay reset

  // 3. Run the active algorithm's per-sample tick (buffers internally; emits delayed).
  float wet = (o->cur_mode == 0)
      ? le_pv_tick (o, fifo, cap, head)                 // phase vocoder
      : le_psola_tick(o, fifo, cap, head);              // PSOLA (D4 fallback inside)

  // 4. Tone low-pass on the wet voice (unchanged character).
  wet = le_octaver_tone(o, wet);                        // one-pole, opens with sm_tone

  // 5. Delay-matched dry (D2): read FIFO at head - latency(cur_mode).
  const float dry = fx_read_frac(fifo, cap, head, (float)le_octaver_latency(o));

  // 6. Mode-switch gain dip (D1) then dry/wet mix.
  const float g = o->xfade;                             // 1 steady, dips on switch
  return dry * (1.0f - o->sm_mix) + g * wet * o->sm_mix;
}
```

**`le_pv_tick`** (phase vocoder, the formant-preserving core), once per
`LE_PV_HOP` samples:
1. Hann-window the latest `N` FIFO samples; `le_rfft_fwd` → `re/im`.
2. Per bin: `mag[k]`, `phase[k]`; phase-difference → **true frequency**
   (standard PV analysis, using `last_phase`).
3. **Formant envelope** `env[k]`: cepstrum of `log(mag)` (`le_rfft_*` on the
   log-magnitude), keep quefrencies `< LE_PV_LIFTER`, exponentiate back → smooth
   spectral envelope.
4. **Whiten → shift → re-apply**: `res[k] = mag[k]/env[k]`; map source bin `k`
   to target `j = round(k·ratio)`; `synMag[j] = res[k]·env[j]` (original
   envelope at the *destination* keeps formants fixed); `synFreq[j] =
   trueFreq[k]·ratio`.
5. Synthesis-phase accumulate into `sum_phase[j]`; build `re/im`; `le_rfft_inv`;
   Hann-window; **overlap-add** into `out`.
6. Each sample call returns the next `out` sample (latency = `N`).

**`le_psola_tick`** (PSOLA), per the D4 contract (detailed/refined in
[part 4](./2026-06-14-feat-formant-preserving-octaver-part-4-plan.md)):
1. **YIN** pitch detect (octave-robust; parabolic-interpolated) over the FIFO
   (vocal range ~60–1000 Hz) → `period`, `voiced` confidence (smoothed).
2. RMS silence floor → silent; `voiced < thresh` (with hysteresis) → return
   delay-matched dry (no grain buzz).
3. Else: place 2·`period` Hann grains at **uniform** pitch-synchronous marks (no
   GCI detection); emit grains spaced `period/ratio`; grains are **not
   resampled**, so formants (grain spectral shape) stay put while pitch (epoch
   rate) shifts. OLA into
   `out`.

`ratio = 2^((shift − 0.5)·48 / 12)` — unchanged mapping (±2 octaves, unison at
0.5), now driven by smoothed `sm_shift`.

### Param model 3 → 4 (native + Dart + UI)

- **`loopy_engine_api.h`**: `#define LE_FX_PARAMS 4`. The atomics arrays
  `a_fx_param[LE_FX_MAX][LE_FX_PARAMS]` resize automatically.
- **`le_fx_default_params`** ([engine.c:2735](../../packages/loopy_engine/src/engine.c)):
  every `case` writes `out[3]`; all non-octaver types set `out[3] = 0.0f`
  (inert). `LE_FX_OCTAVER`: `{0.25 (octave down), 0.5 (tone), 0.5 (mix),
  0.0 (mode = PV)}`.
- **Other effects read only their own params** — confirm none read `p[3]`
  (M3); output is byte-for-byte unchanged after the widening.
- **Dart `kTrackEffectParams = 4`** ([track_effect.dart:13](../../packages/loopy_engine/lib/src/track_effect.dart)).
  Per-type `params` lists are the UI source of truth (the editor renders
  `type.params.length` sliders, **not** `kTrackEffectParams` —
  [effect_params_editor.dart:99](../../lib/common/effect_params_editor.dart)),
  so **only the octaver's list grows** (add a discrete `Mode` control with 1
  division / 2 states and a readout "Phase Vocoder" / "PSOLA"). No other effect
  gains a slider.
- **`defaultParams`** ([track_effect.dart:108](../../packages/loopy_engine/lib/src/track_effect.dart))
  grow to length 4, octaver `mode` default `0.0`.
- **`fromJson` migration (D6)**: pad/truncate the decoded `params` to
  `kTrackEffectParams`, defaulting missing entries (so old 3-param chains load).
- **l10n**: add mode label + two readout strings to `app_en.arb` / `app_es.arb`.
- **FFI**: regenerate `loopy_engine_bindings.dart` via ffigen (doc/const only;
  the array sizing is compile-time in C).

### Latency exposure (D3)

Add an effect-latency field to the published snapshot (reuse the latency-state
struct surface in [loopy_engine_api.h](../../packages/loopy_engine/src/loopy_engine_api.h))
reporting the active octaver's added frames, so the Flutter layer can render the
"PV adds ~21 ms; use PSOLA live" hint. Record-offset auto-compensation for an
in-chain octaver is **documented, deferred** (§Out of Scope).

### Allocation / reset (control thread)

- **`le_fx_prepare_entry`** ([engine.c:2789](../../packages/loopy_engine/src/engine.c)):
  for `LE_FX_OCTAVER`, in addition to the two `delay` rings (`needs_right`),
  allocate `oct[index][chan].out` (`LE_PV_N`), `.last_phase` and `.sum_phase`
  (`LE_PV_BINS`) for `chan ∈ {0,1}` when `NULL`. **Partial-OOM rollback** parity
  (C3): free only what *this call* newly allocated (track per-buffer flags),
  null them, return `LE_ERR_INVALID`; never free buffers the slot already owned.
- **`le_fx_entry_reset`** ([engine.c:524](../../packages/loopy_engine/src/engine.c)):
  zero the octaver scalars for both channels (`hop_count`, `out_pos`, `period`,
  `voiced`, epochs, `sm_*`, `cur_mode`, `xfade = 1`) and `memset` the three PV
  buffers to 0 **if allocated**. Stays allocation-free (runs on the audio thread
  via the `SET_*_FX` handlers).
- **`le_lane_reset` / `le_monitor_lane_reset`** (~engine.c:1521 / ~1540) and
  **`le_engine_destroy`** (both lane loops): `free` the three `oct[s][chan]`
  buffers (both channels) and null them, alongside the existing `delay[s][...]`
  frees.
- **Reorder/retype (M1)**: a reorder that keeps the slot `OCTAVER` preserves
  params (incl. `mode`) and does **not** reallocate (existing "re-seed defaults
  only when `type` changes" logic at engine.c:2819 already guards this); retype
  away frees the octaver buffers; retype back reallocates + re-seeds.

### Public surface

Effect type list is unchanged (still `LE_FX_OCTAVER`). The param **count** grows
(documented in the api header + `track_effect.dart`). `fx_octaver`'s header
comment is rewritten to describe the PV/PSOLA design, latency, and the D1–D6
contracts.

## Edge Cases (from user-flow analysis)

- **C2/D1 mode chatter** — discrete control + gain-dip; no per-buffer PV↔PSOLA
  flapping; no click on toggle.
- **C4 CPU spike** — one `N`-FFT (+2 cepstrum `N`-FFTs) per hop per channel per
  octaver. Worst case bounded by `LE_FX_MAX` octavers × active lanes/monitors;
  `N = 1024` keeps per-hop cost modest and amortized over 256 samples. Measure
  against the audio deadline at max chain depth.
- **H1/D2 comb** — flat magnitude at `mix = 0.5` (no deep notches) for both
  modes; dry-delay tracks the active mode and is re-matched across a switch.
- **H3 zipper** — full-range `shift`/`tone`/`mix` drags are click-free
  (smoothed). `shift` snaps to 48 semitone divisions; each step glides via the
  smoother.
- **H4 PSOLA fallback** — unvoiced/silent/poly handled per D4.
- **H5/D5 mono** — `l == r` in → `l == r` out (deterministic per-channel).
- **M4 sample rate** — buffers sized from a fixed `N` (not sample rate), so
  latency in **ms** scales with rate as expected; guard `cap <= LE_PV_N`.

## Technical Considerations

- **Real-time safety** — unchanged discipline: control thread pre-allocates all
  PV/PSOLA buffers in `le_fx_prepare_entry` before publishing the type; the
  audio callback only reads/writes pre-allocated memory and stack scratch. No
  alloc/lock/syscall reachable from `fx_octaver` / `fx_apply_chain` (assert in
  test).
- **Latency** — `N` samples (PV) / ~one period (PSOLA). Internal dry-delay keeps
  the mix phase-coherent; the live-monitoring cost is surfaced, not hidden.
- **CPU** — see C4 above; the rewrite is markedly heavier than the granular
  version but bounded and amortized. PSOLA is cheaper than PV (no FFT) — another
  reason to steer live monitoring to it.
- **Memory** — per OCTAVER slot per channel: `out[N]` + `last_phase[BINS]` +
  `sum_phase[BINS]` ≈ `1024 + 513 + 513` floats ≈ 8 KB; ×2 channels ≈ 16 KB per
  slot, lazily allocated only for octaver slots. The 1 s input rings are
  unchanged (reused).
- **Shared surface** — one `fx_octaver` serves track lanes and monitor lanes, so
  the improvement lands on both.
- **Determinism** — no `rand`/time-seeded state; required for D5 and for
  reproducible golden tests.

## Implementation Order

1. **`fft.h`** — header-only radix-2 FFT + real-FFT helpers + shared Hann table;
   unit-test the FFT in isolation (round-trip, known spectra).
2. **`engine_private.h`** — add `le_octaver_state` + `oct[LE_FX_MAX][2]`.
3. **`engine.c`** — `#include "fft.h"`; rewrite `fx_octaver` + helpers
   (`le_octaver_smooth`, `le_octaver_handle_mode_switch`, `le_octaver_tone`,
   `le_octaver_latency`, `le_pv_tick`, `le_psola_tick`). Keep the call site in
   `fx_apply_chain` unchanged.
4. **`engine.c`** — `le_fx_default_params` (4 entries, octaver mode = 0);
   `le_fx_prepare_entry` (allocate + OOM rollback); `le_fx_entry_reset`,
   `le_lane_reset`, `le_monitor_lane_reset`, `le_engine_destroy` (free + zero).
5. **`loopy_engine_api.h`** — `LE_FX_PARAMS 4`; latency-report field; doc
   comments (drop the granular description, document PV/PSOLA + D1–D6).
6. **Dart** — `kTrackEffectParams = 4`; octaver `params` gains discrete `Mode`;
   `defaultParams` length 4; `fromJson` pad/truncate migration; l10n strings;
   ffigen regenerate.
7. **Tests** — native DSP + persistence + allocation-assert (see §Testing).
8. **Verify** — native test ALL PASSED; `flutter analyze` clean; `flutter test`
   green; `flutter build windows --debug --target lib/main_development.dart`.

## Acceptance Criteria

- [ ] A 220 Hz mono sine, octave-up (`shift` = 0.75), **phase vocoder**: output
      fundamental ≈ 440 Hz **and** the spectral **centroid/formant** stays near
      the input's (formant preserved) — measurably unlike a naive resample
      (centroid would roughly double).
- [ ] Same tone octave-**down** likewise preserves the envelope; output ≈ 110 Hz.
- [ ] **PSOLA** on a solo-voice-like input shifts pitch with formants preserved;
      on **silence** → silent; on **unvoiced/noise** → delay-matched dry (no
      buzz) (D4).
- [ ] **Mono coherence**: a mono input (`l == r`) yields `l == r` out in both
      modes (D5).
- [ ] **No comb at `mix = 0.5`**: broadband input shows no deep periodic notches
      (dry delay-matched, D2), both modes.
- [ ] **Mode toggle** PV↔PSOLA mid-playback is click-bounded (gain-dip, D1); a
      slider parked near 0.5 does not flap.
- [ ] **Zipper-free**: a full-range `shift`/`tone`/`mix` drag produces no clicks.
- [ ] **Persistence**: an old 3-param saved chain loads into a valid 4-param
      octaver with `mode` = PV; UI does not crash (D6).
- [ ] **Other effects unchanged**: drive/filter/delay/tremolo/echo/reverb output
      byte-for-byte identical after the param widening; no extra UI slider (M3).
- [ ] **No audio-thread allocation** for `LE_FX_OCTAVER` (assert).
- [ ] **Lifecycle**: rapid reorder/retype/remove of an octaver slot under audio
      — no leak, no use-after-free, no state bleed (M1).
- [ ] **Latency surfaced**: snapshot reports the active octaver's added frames;
      UI can render the PV-latency hint (D3).
- [ ] All gates green: native ALL PASSED, `flutter analyze` clean,
      `flutter test` green, `flutter build windows --debug` compiles.

## Testing

Native (`packages/loopy_engine/src/test/test_engine_core.c`, MSVC/mingw) unless
noted:

- **`test_fft_roundtrip`** — `le_rfft_fwd`→`le_rfft_inv` reconstructs a signal;
  a pure sine yields a single spectral peak at the right bin.
- **`test_octaver_pv_shifts_pitch_preserves_formant`** — sine in, assert output
  fundamental ≈ `ratio·f` (dominant-bin detection) **and** spectral centroid
  ≈ input centroid (formant preserved), up and down an octave.
- **`test_octaver_psola_voice_and_fallback`** — voiced input shifts; silence →
  silence; noise/unvoiced → dry passthrough (D4).
- **`test_octaver_mono_coherent`** — `l == r` in → `l == r` out, both modes (D5).
- **`test_octaver_mix_no_comb`** — broadband in at `mix = 0.5`; assert no deep
  comb notch in the magnitude response (D2).
- **`test_octaver_mode_switch_no_click`** — toggle `p3` mid-stream; assert the
  sample-to-sample delta stays bounded (no discontinuity spike) (D1).
- **`test_octaver_param_smoothing_no_zipper`** — sweep `shift`/`mix`; bounded
  deltas (H3).
- **`test_octaver_no_audio_thread_alloc`** — run the callback path for an
  octaver slot under an allocation guard/counter; assert zero allocations.
- **`test_octaver_lifecycle`** — reorder/retype/remove an octaver slot while
  processing; assert no leak/UAF and that a different effect landing on the slot
  index is unaffected (M1).
- **Unchanged FX tests** (drive/filter/delay/tremolo/echo/reverb,
  bypass/count/order, nondestructive) stay green — they run on mono inputs and
  do not touch `p[3]`.
- **Dart** — `test/.../track_effect_test.dart`: a length-3 `fromJson` fixture
  decodes to a length-4 octaver with `mode` = PV (D6); `defaultParams` are
  length 4; widget test that the octaver editor shows a discrete Mode control and
  other effects show their original slider counts (M3).

## Dependencies & Risks

- **Touches a shipped effect + the global param width.** Mitigated by:
  per-type UI slider sourcing (only octaver grows), the byte-for-byte
  no-change assertion for other effects, and the persistence migration test.
- **Real-time CPU (C4)** is the headline risk — FFT per hop across many lanes.
  Mitigated by `N = 1024`, amortization, PSOLA (no FFT) for the latency-/CPU-
  sensitive live path, and an explicit worst-case measurement gate.
- **PSOLA fragility (H4)** on non-monophonic input — bounded by the
  voicing-confidence fallback to dry; "solo voice" expectation documented.
- **Monitor latency (H2/D3)** — surfaced, with full record-path compensation
  deferred (§Out of Scope) to keep the PR scoped.
- **FFT correctness** — isolated `test_fft_roundtrip` before it feeds the PV.
- **Builds on the full-stereo FX chain** — the per-channel `oct[..][2]` assumes
  `le_fx_state` is already 2D (it is, on disk).

## Out of Scope (follow-ups)

- **Record-offset auto-compensation** for an octaver in the
  monitored-and-recorded path (D3/H2) — surface latency now; auto-align overdub
  timing later.
- **Equal-power PV↔PSOLA crossfade** running both engines (D1 alternative) — the
  gain-dip ships first.
- **Per-effect variable param counts** — keep the simple global `LE_FX_PARAMS`;
  do not refactor to per-type widths.
- **Formant-shift control** (move formants independently of pitch) — the
  envelope is preserved 1:1 for now; a `formant` knob is a future enhancement.

## References & Research

- Octaver + chain: [engine.c:411](../../packages/loopy_engine/src/engine.c)
  (`fx_octaver`), [engine.c:622](../../packages/loopy_engine/src/engine.c)
  (`fx_apply_chain`, stereo contract).
- DSP state: `le_fx_state` in
  [engine_private.h:80](../../packages/loopy_engine/src/engine_private.h).
- Alloc/reset/destroy: `le_fx_prepare_entry` (engine.c:2789),
  `le_fx_entry_reset` (engine.c:524), `le_fx_default_params` (engine.c:2735),
  `le_lane_reset`/`le_monitor_lane_reset` (engine.c:1519/1540), destroy loops.
- Param surface: `LE_FX_PARAMS` ([loopy_engine_api.h:168](../../packages/loopy_engine/src/loopy_engine_api.h)),
  `kTrackEffectParams`/`defaultParams`/`fromJson`
  ([track_effect.dart:13,108,174](../../packages/loopy_engine/lib/src/track_effect.dart)),
  per-type slider loop ([effect_params_editor.dart:99](../../lib/common/effect_params_editor.dart)).
- Latency surface: `le_latency_state` / `measured_latency_ms` / record-offset
  ([loopy_engine_api.h:45,335,520](../../packages/loopy_engine/src/loopy_engine_api.h)).
- Predecessor: full-stereo FX chain
  ([docs/plan/2026-06-14-fix-stereo-effects-chain-plan.md](./2026-06-14-fix-stereo-effects-chain-plan.md)).
- Algorithms: phase-vocoder pitch shift with cepstral formant preservation
  (whiten → shift residual → re-apply original envelope); TD-PSOLA with
  YIN voicing detection (octave-robust).
