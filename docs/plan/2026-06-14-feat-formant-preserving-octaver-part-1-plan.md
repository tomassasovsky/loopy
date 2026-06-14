---
title: "feat: header-only FFT primitive (octaver part 1)"
type: feat
date: 2026-06-14
---

## feat: header-only FFT primitive — Standard (part 1 of 5)

> Part 1 of the formant-preserving octaver split
> ([umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md)). A pure,
> self-contained FFT utility with **no** engine coupling — it can land and be
> trusted before any DSP rewrite consumes it.

## Overview

Add a header-only radix-2 FFT (`packages/loopy_engine/src/fft.h`) that the phase
vocoder (part 3) will use, plus an isolated round-trip test. Header-only means
**no new translation unit**, so the CMake source list
([src/CMakeLists.txt](../../packages/loopy_engine/src/CMakeLists.txt)), the macOS
podspec glob, and the test build's explicit file list are all untouched.

## Problem Statement / Motivation

The codebase has no FFT (`grep -ri fft` over `src/` minus miniaudio = none). The
formant-preserving phase vocoder needs a forward/inverse real FFT for STFT
analysis/synthesis and for cepstral envelope extraction. Shipping it first, as a
pure primitive with its own test, lets a reviewer judge correctness from the FFT
spec alone and lets part 3 assume a trusted FFT.

## Proposed Solution

```c
// packages/loopy_engine/src/fft.h — included by a single TU (engine.c in part 3;
// the test TU here). All functions static; caller owns all buffers (no malloc).

#define LE_FFT_PI 3.14159265358979323846f

// In-place iterative radix-2 complex FFT. n MUST be a power of two.
// inverse == 0: forward; inverse != 0: inverse WITHOUT 1/n scaling
// (callers that need orthonormal round-trip divide by n themselves; le_rfft_inv does).
static void le_fft(float* re, float* im, int n, int inverse);

// Real input x[n] -> half spectrum re/im[0..n/2] (n/2+1 bins). re/im sized >= n/2+1.
static void le_rfft_fwd(const float* x, float* re, float* im, int n);

// Half spectrum re/im[0..n/2] -> real output y[n], normalized by 1/n.
static void le_rfft_inv(const float* re, const float* im, float* y, int n);
```

- **Implementation:** standard bit-reversal permutation + iterative
  Danielson–Lanczos butterflies. The real-FFT helpers run a length-`n` complex
  FFT (simplest correct approach; the packed real-FFT optimization is not worth
  the complexity at `n = 1024`) and expose the non-redundant `n/2+1` bins.
- **Shared Hann window table:** a file-scope `static float le_hann[LE_PV_N]`
  built once under a guarded init (`static int le_hann_ready`). Read-only,
  shared across all instances — **not** per-channel state. (The `LE_PV_*`
  constants live with the consumer in part 3; for part 1 the table init takes an
  explicit size so `fft.h` has no dependency on engine constants.)
- **Portability:** pure C11, no platform headers; compiles under MSVC
  (`/std:c11`), Clang, and GCC.

## Dependencies

- None. Targets the branch carrying the full-stereo FX chain (so it stacks
  cleanly under part 3), but `fft.h` itself depends on nothing in the engine.

## Implementation Order

1. Write `packages/loopy_engine/src/fft.h` (`le_fft`, `le_rfft_fwd`,
   `le_rfft_inv`, guarded Hann-table helper).
2. Add `test_fft_roundtrip` to
   [test_engine_core.c](../../packages/loopy_engine/src/test/test_engine_core.c)
   and **register it in `main()`'s call list** (the runner has no auto-discovery
   — every test is a manual `RUN(test_x)` line).
3. Build & run the native test on Windows (MSVC) and Linux/macOS (clang).

## Acceptance Criteria

- [ ] `le_rfft_fwd` → `le_rfft_inv` reconstructs a random signal to within a
      small epsilon (e.g. `< 1e-4` max abs error for `n = 1024`).
- [ ] A pure sine at bin `k` yields a single dominant magnitude peak at bin `k`
      (neighbors near zero).
- [ ] Inverse transform is correctly `1/n`-scaled (DC of a constant input round-
      trips to the same constant).
- [ ] Forward of a real impulse yields ~flat magnitude across bins.
- [ ] Native test suite still prints `ALL PASSED` (MSVC + clang).

## Testing

- **`test_fft_roundtrip`** (in `test_engine_core.c`): random buffer round-trip
  error bound; single-sine single-peak; impulse → flat magnitude; constant → DC.
  Registered in the `main()` call list.

## Dependencies & Risks

- **Correctness risk** is contained: this is the one place FFT math is verified
  in isolation, before part 3 feeds it. Low risk — textbook algorithm, fixed
  power-of-two size.
- **Build risk: none** — header-only, no build-file edits.

## References & Research

- Build source list (unchanged): [src/CMakeLists.txt](../../packages/loopy_engine/src/CMakeLists.txt).
- Test runner (manual `main()` registration): [test_engine_core.c](../../packages/loopy_engine/src/test/test_engine_core.c).
- Consumer: part 3 phase vocoder
  ([part-3](./2026-06-14-feat-formant-preserving-octaver-part-3-plan.md)).
