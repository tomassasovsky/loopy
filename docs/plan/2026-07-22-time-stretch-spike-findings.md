---
title: "spike D0: time-stretch benchmark findings (Signalsmith Stretch)"
type: spike
date: 2026-07-22
issue: 263
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

## Spike D0 — can loopy time-stretch 8 tracks × 8 lanes in real time?

**Short answer: yes — GO for 0.5×–2×, inline on the audio thread, no worker
thread needed.** With `presetCheaper` and hop-phase staggering, even the
absolute worst case (64 concurrent mono stretch streams) costs **p99 ≈ 2.3 ms
per 10 ms block (≈ 20 % of one core)** on the dev machine. The realistic
per-track case (8 streams) is an order of magnitude below every threshold.
The varispeed leg (linear-interp resample) is effectively free.

### What was benchmarked

- **Library:** [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch)
  (MIT), release tag **`1.1.0`**, commit
  **`44c8f865af9da8c29cc4a70a2d5a3ec83639c711`** (2025-01-29). Snapshot
  vendored (no `.git`) at
  `packages/loopy_engine/src/test/bench/third_party/signalsmith-stretch/`
  — kept: `signalsmith-stretch.h`, `dsp/` (bundled signalsmith-dsp, also
  MIT), licenses, README; stripped: `web/` (compiled JS + mp3), `cmd/`
  (CLI example). Header-only C++ template; D1 vendors it properly into
  `src/stretch/`.
- **Harness:** `packages/loopy_engine/src/test/bench/bench_stretch.cpp`,
  built by `bench.sh` (host `c++`, `-std=c++17 -O2 -DNDEBUG`). **Outside the
  native test gate** (`run_native_tests.sh` compiles explicit file lists and
  never looks in `src/test/bench/`).
- **Signal:** 10 s of 48 kHz mono — five AM-modulated sines (82–1245 Hz)
  plus a 30 ms decaying noise burst every 500 ms (keeps the library's
  silence bypass off and exercises both tonal and transient paths).
- **Model:** streaming in 480-frame (10 ms) output blocks. Ratio =
  output/input = `original_tempo / current_tempo` (D13), controlled purely
  by per-call sample counts with fractional accumulation.
- **Machine:** Apple M4 Pro (10 P + 4 E cores, 48 GB), Apple clang 21,
  macOS 26. **Caveat:** this is the fast dev machine; CI runners and older
  hardware are slower — treat ratios between configs as portable, absolute
  numbers as best-case. The bench thread is *not* RT-prioritized, so the
  occasional 15–26 ms `max` outlier is scheduler preemption, not the
  library; a real audio thread at RT priority will not see those. Judge
  against p99.
- Reproduce: `cd packages/loopy_engine/src/test/bench && ./bench.sh`
  (add `--wav <dir>` to dump listening files, `--only-wav` to skip timing).

### Memory: per-stream state

| preset  | heap/stream | STFT block | interval | total latency |
|---------|------------:|-----------:|---------:|--------------:|
| default | 2 467 KiB   | 5760       | 1440     | 120 ms        |
| cheaper |   579 KiB   | 4800       | 1920     | 100 ms        |

Scaled: 8 streams = 19.3 MiB (default) / 4.5 MiB (cheaper); 64 streams =
154 MiB (default) / **36 MiB (cheaper)**.

**Input retention (D13 stretch-from-original):** 48 kHz mono float32 =
**11.0 MiB per minute of source per stream** — but this is the *original
layer buffer the engine already holds* (live buffers + undo pool,
`LE_POOL_SLOTS`). Streaming inline from originals creates **no stretched
copy at all**, so D13's "doubles peak memory" estimate collapses to
*stretcher state only* (≤ 36 MiB worst case) plus scratch blocks. The
double-memory budget is validated with a large margin — the actual overhead
is roughly 1–3 % of the content memory it operates on, not 100 %.
(A worker-thread *pre-render* design would have paid the full 2× — another
reason inline wins.)

### Single stream (20 s of output, per-block times)

| preset  | ratio | p50 ms | p99 ms | mean ms | CPU % core |
|---------|------:|-------:|-------:|--------:|-----------:|
| default | 0.50  | 0.002  | 0.134  | 0.036   | 0.4 %      |
| default | 0.80  | 0.002  | 0.120  | 0.035   | 0.4 %      |
| default | 1.20  | 0.002  | 0.119  | 0.035   | 0.4 %      |
| default | 2.00  | 0.001  | 0.124  | 0.036   | 0.4 %      |
| cheaper | 0.50  | 0.002  | 0.121  | 0.030   | 0.3 %      |
| cheaper | 0.80  | 0.002  | 0.120  | 0.029   | 0.3 %      |
| cheaper | 1.20  | 0.002  | 0.124  | 0.029   | 0.3 %      |
| cheaper | 2.00  | 0.001  | 0.126  | 0.029   | 0.3 %      |

Cost is nearly ratio-independent (the STFT hops per *output* interval).
The p50/p99 split shows the cost shape: most blocks are ~2 µs of copying;
every third (default) or fourth (cheaper) block pays a ~0.12 ms FFT hop.

### Concurrent streams — naive (all hops aligned)

All stretchers configured identically start with the same hop phase — and a
quantized tempo change retargets every stream at the same instant, so this
alignment is the honest default.

| streams | preset  | ratio | p50 ms | p99 ms | CPU % core |
|--------:|---------|------:|-------:|-------:|-----------:|
| 8       | default | 0.50  | 0.019  | 0.915  | 2.9 %      |
| 8       | default | 2.00  | 0.011  | 0.995  | 2.9 %      |
| 8       | cheaper | 0.50  | 0.019  | 0.966  | 2.4 %      |
| 8       | cheaper | 2.00  | 0.011  | 0.971  | 2.3 %      |
| 64      | default | 0.50  | 0.172  | 7.434  | 24.4 %     |
| 64      | default | 2.00  | 0.105  | 7.272  | 23.8 %     |
| 64      | cheaper | 0.50  | 0.168  | 7.674  | 19.9 %     |
| 64      | cheaper | 2.00  | 0.101  | 7.672  | 19.4 %     |

(Ratios 0.8 / 1.2 sit between the extremes; full tables print from the
harness.) 8 streams pass the **3 ms on-thread bar** with 3× headroom even
aligned. 64 aligned streams fail it (p99 ≈ 7.3–7.7 ms) and only marginally
fit the 8 ms worker bar — aligned per-lane-at-ceiling is not shippable.

### Concurrent streams — hop-staggered (each stream primed `i·interval/N` output samples apart)

| streams | preset  | ratio | p50 ms | p99 ms | CPU % core |
|--------:|---------|------:|-------:|-------:|-----------:|
| 8       | default | 0.50  | 0.312  | 0.420  | 2.9 %      |
| 8       | default | 2.00  | 0.313  | 0.416  | 2.9 %      |
| 8       | cheaper | 0.50  | 0.234  | 0.309  | 2.4 %      |
| 8       | cheaper | 2.00  | 0.221  | 0.299  | 2.3 %      |
| 64      | default | 0.50  | 2.438  | 3.176  | 25.0 %     |
| 64      | default | 2.00  | 2.389  | 2.744  | 24.1 %     |
| 64      | cheaper | 0.50  | 1.986  | 2.257  | 20.0 %     |
| 64      | cheaper | 2.00  | 1.891  | 2.107  | 19.0 %     |

Staggering flattens the hop spikes into the mean: **64 × cheaper drops to
p99 ≈ 2.1–2.3 ms — under the 3 ms on-thread bar with ~25 % headroom** even
at the absolute lane ceiling. 64 × default is borderline (2.6–3.2 ms):
usable to roughly half the ceiling (~32 streams) but not shippable at 64 on
slower hardware.

### Varispeed leg (linear-interp resampler — the Sheeran "Sync Audio ON + Stretch OFF" mode)

| streams | rate | p50 ms | p99 ms | CPU % core |
|--------:|-----:|-------:|-------:|-----------:|
| 8       | 2.0  | 0.007  | 0.008  | 0.07 %     |
| 8       | 0.5  | 0.007  | 0.007  | 0.07 %     |
| 64      | 2.0  | 0.054  | 0.071  | 0.55 %     |
| 64      | 0.5  | 0.053  | 0.068  | 0.55 %     |

Near-free, as expected: ~100× cheaper than stretch. **Shipping the
two-toggle model is a product decision, not a perf one** — the engine leg
costs nothing (recommend adding it in D2; linear interp is adequate at
0.5–2×, upgradeable to cubic later without API change). If it ships, the
manifest needs the second flag (`timeStretch` alongside `syncAudioToTempo`)
— flag for the D12 name review; no conflict found with either provisional
name (`syncAudioToTempo`, `originalTempoBpm` confirmed usable).

### Recommendation

**Go.** Use **`presetCheaper`**, one stretcher **per lane** (not per track),
running **inline on the audio thread**, with **hop-phase staggering** at
stream creation. Per-lane is the honest granularity: lanes carry different
audio, and one-stretcher-per-track would require mixing lanes *before* the
stretcher, putting per-lane volume/mute/FX behind the stretcher's 100 ms
latency and baking the lane mix — an audible regression for a ~17 % CPU
saving we do not need. Lazily allocate stretchers only for lanes with
content (typical sessions run ~8 active lanes ⇒ p99 ≈ 0.3 ms, noise); the
64-lane ceiling still fits the 3 ms bar with headroom. `presetCheaper` wins
on every measured axis (4.3× less memory, 100 ms vs 120 ms latency, ~20 %
less CPU, better staggered p99); `presetDefault` remains a one-line
`configure()` swap if listening tests (D3 manual gate, WAV dump in the
harness) find cheaper's quality lacking — it is viable to ~32 concurrent
streams. Skip the worker-thread/crossfade-fallback machinery entirely:
inline passes, and the worker design would also have reintroduced the 2×
memory cost and a scheduling seam. Add the varispeed leg — it is free.

### API notes for D2 (integration surprises)

1. **No ratio parameter.** `process(in, nIn, out, nOut)` — the ratio is
   whatever sample counts you pass per call. The engine must run a
   fractional input accumulator per stream (`frac += nOut/ratio`; feed
   `floor` samples). Retargeting tempo is just changing the per-block input
   count — no reset, no glitch at the API level; the plan's ratio
   deadband/crossfade (G26 lineage) may simplify to a short input-count
   glide.
2. **One window of latency.** `inputLatency() + outputLatency()` = 100 ms
   (cheaper) / 120 ms (default). The lane read-head must *lead* the musical
   position by `inputLatency` input frames, and loop-phase math must add
   `outputLatency` on the output side. On (re)start, `seek()` with one
   block + one interval of pre-roll primes the stream; the first ~window of
   output after a cold start is transient — prime during count-in/quantize
   wait or crossfade in.
3. **RT-safe after configure.** Zero heap allocations observed across all
   32 sustained-streaming configs (global new/delete tracking; the
   `peaks` reserve of `bands/2` is a structural bound — peak runs consume
   ≥ 2 bands each). `configure()`/`presetCheaper()` allocates megabytes —
   construct on the control thread, hand off to audio (fits the existing
   pool/slot handoff patterns). `reset()` is allocation-free (same-size
   `assign`) and fine on-thread.
4. **C++ in a C engine.** Header-only C++14+ template; engine core is C.
   Needs one small C++ TU shim exposing a C ABI (precedent: the C++
   plugin-host sources already compiled into the engine).
5. **Seed the RNG.** The default constructor seeds from
   `std::random_device` (phase randomization) — construct with a fixed seed
   in tests or goldens will not reproduce.
6. **Stagger on creation.** Priming stream *i* by `i · interval / N` output
   samples cut 64-stream p99 by 3.4× (7.7 → 2.3 ms). Cheap, do it always.
7. **Layer subtlety for D13:** after a tempo change, an overdub records at
   the *current* tempo while older layers stretch from *their* original
   tempos — audible playback must therefore mix per-layer stretcher outputs
   (streams scale with *distinct-native-tempo layer groups*, not just
   lanes) until a flatten. The 64-stream ceiling number is the budget
   guard for that case too.

### Threshold scorecard

| Scenario (worst ratio) | p99 | 3 ms inline bar | 8 ms worker bar |
|---|---:|:---:|:---:|
| 8 streams, cheaper, staggered | 0.31 ms | pass (10×) | pass |
| 8 streams, default, staggered | 0.42 ms | pass (7×) | pass |
| 64 streams, cheaper, staggered | 2.26 ms | **pass** | pass |
| 64 streams, default, staggered | 3.18 ms | fail (marginal) | pass |
| 64 streams, either, aligned | 7.3–7.7 ms | fail | pass (marginal) |
| 64 varispeed streams | 0.07 ms | pass (40×) | pass |
