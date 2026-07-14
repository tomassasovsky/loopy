---
date: 2026-07-13
topic: fix-echo-vst3-samplerate-scaled-ring
---

# Fix: Loopy Echo VST3 delay-ring capacity doesn't scale with host sample rate

## What We're Building

`packages/loopy_engine/vst3/echo/processor.h` hardcodes
`static constexpr int kEchoCapFrames = 48000;` and the Echo processor has no
`setupProcessing()` override, so the delay-ring capacity never adapts to the
host's negotiated sample rate. `fx_echo`'s normalized "Time" parameter maps
directly onto this cap in samples (`engine_fx.c`), so at any sample rate other
than 48 kHz the plugin's actual max echo time diverges from the live engine
(`engine.c`: `fx_delay_frames = sample_rate`) and from the same normalized
value at a different sample rate — e.g. at 96 kHz max delay time is 0.5 s
instead of 1 s; at 44.1 kHz it's ~1.088 s instead of 1 s.

The sibling Reverb VST3 plugin (`packages/loopy_engine/vst3/reverb/`) already
solves exactly this problem: it has a `setupProcessing()` override, a `cap_`
member recomputed from `processSetup.sampleRate`, a public static
`computeRingCapacity(double sampleRate)` helper, and a
`ringCapacityForTesting()` accessor used by its own 96 kHz regression test.

This fix mirrors Reverb's proven pattern onto Echo: move ring sizing out of
`initialize()` and into `setupProcessing()`, size it to the real negotiated
sample rate, and add the same testing hooks plus a sample-rate regression
test.

## Why This Approach

**Mirror Reverb exactly, adapted for Echo's per-channel ring (chosen).**
Reverb already solved this identical problem in the same codebase, using the
same underlying `engine_fx.h` seam (`le_fx_prepare` / `fx_apply_chain`).
Echo's `fx_echo` (`engine_fx.c`) already guards `buf == NULL` safely (dry
passthrough), the same guard `fx_reverb` relies on before its ring is first
sized in `setupProcessing()` — so the same lazy-allocate-on-setupProcessing
structure is safe to reuse. Echo differs from Reverb in one place: like
Delay, Echo's engine dispatch table wires `LE_FX_ECHO` to
`fx_stereo_ring_prepare` (`engine_fx.c`'s `LE_FX` table), which allocates one
ring *per channel* (`delay[slot][0]` and `delay[slot][1]`), not Reverb's
single packed `delay[slot][0]` buffer — so `setupProcessing()` must free both
channels on a cap change, not just one.

Two alternatives were considered and rejected:

- **Recompute the cap inside `process()` from `processSetup.sampleRate` every
  block, without a `setupProcessing()` override.** Rejected: `processSetup` is
  only refreshed by `setupProcessing()`; reading it in `process()` without
  ever overriding the callback still leaves the ring sized however
  `initialize()` left it. It also reallocates on a hot path unless the same
  "only reallocate if changed" cap-diffing `setupProcessing()` gives for
  free, once per rate change instead of once per block, is duplicated there
  too. No advantage over mirroring Reverb, and it's a new pattern instead of
  a proven one.
- **Keep the fixed 48000 cap but rescale the Time parameter's mapping by
  `sampleRate / 48000` inside `fx_echo`/`engine_fx.c` instead of resizing the
  ring.** Rejected: `engine_fx.c` is the shared DSP core used by the live
  engine and every other FX wrapper (Delay also uses
  `fx_stereo_ring_prepare`); changing its param-to-samples mapping would be a
  much larger blast radius than fixing one VST3 wrapper's ring sizing, and it
  still wouldn't fix the actual bug (a ring that's too small for the sample
  rate silently truncates at the top of the delay range — same failure
  Reverb's fixed-cap-comment documents for its own comb/allpass network).

## Key Decisions

- **Move `le_fx_prepare` from `initialize()` to `setupProcessing()`,
  matching Reverb's structure.** `initialize()` no longer prepares the ring;
  `setupProcessing()` computes the new cap, frees the old ring only if the
  cap changed (`fx_alloc_ring` only allocates when the pointer is `NULL`),
  and calls `le_fx_prepare` with the new cap. Before the first
  `setupProcessing()` call, `fx_.delay[0][0]`/`[1]` are `NULL` and
  `fx_echo`'s own `buf == NULL` guard makes `process()` a safe dry
  passthrough — exactly Reverb's documented behavior.
- **Free both `delay[0][0]` and `delay[0][1]` on a cap change**, not just
  one — Echo shares Delay's per-channel ring allocation
  (`fx_stereo_ring_prepare`), unlike Reverb's single packed buffer. Copying
  Reverb's free logic verbatim (freeing only `[0]`) would leak the old `[1]`
  buffer on every sample-rate change.
- **Keep `kEchoCapFrames` as a named constant, repurposed as `cap_`'s initial
  value (48000), not removed.** It is referenced outside `echo/`:
  `vst3/test/test_echo_parity.cpp`. Removing it would break the build. Its
  doc comment must be corrected to drop the "copies Delay's fixed sizing...
  D-SEAM scope" framing (superseded by this fix) and instead describe it as
  the pre-`setupProcessing()` default / initial allocation size, matching
  `cap_`'s own default-value framing in Reverb's header.
- **Add `computeRingCapacity(double sampleRate)` as a public static method,
  identical formula to Reverb's (`round(sampleRate)`, floor of 1).** This is
  the one used by both `setupProcessing()` and the golden-parity harness's
  `computeCap` — same reasoning Reverb already established: a single source
  of truth the harness references instead of re-deriving.
- **Add `ringCapacityForTesting()` accessor and a `cap_` member**, mirroring
  Reverb's header, so a new wrapper test can assert the ring size itself
  (not just "produces non-silent output," which a truncated ring would also
  do).
- **Create `test_vst3_echo_wrapper.cpp`** — Echo currently has no
  wrapper-level test file at all (only `test_vst3_echo_ids.cpp`), unlike
  Delay and Reverb. This fix adds one, covering the same baseline coverage
  those two files establish (defaults-match-engine, param round-trip,
  set-state restore, controller param registration, controller state sync)
  plus a 96 kHz ring-scaling regression test and a
  reallocate-on-rate-change regression test (the latter specifically
  exercising the free-both-channels branch, the Echo/Delay-specific risk
  Reverb's single-buffer test can't cover). Wired into
  `CMakeLists.txt` via `loopy_vst3_add_wrapper_test(echo)`.
- **Update `vst3/test/test_echo_parity.cpp`'s `computeCap` lambda** from the
  fixed `kEchoCapFrames` literal to `&loopy_vst3_echo::Processor::computeRingCapacity`,
  matching how `test_reverb_parity.cpp` already wires its own `computeCap`.
  This is required for the golden-parity harness to keep passing at
  non-48kHz rates in its existing `{44100, 48000, 88200, 96000}` sweep — once
  the hosted path's real cap scales with sample rate, the harness's
  direct-`fx_apply_chain` reference must use the same scaled cap or a cap
  mismatch alone (not a real bug) would fail the diff.
- **Update the comment in `vst3/test/host_harness.h`** describing which
  plugins scale their ring capacity, so it reflects Echo now scaling
  alongside Reverb (Delay remains fixed-cap — that is a separate, already
  identified but not-yet-landed finding, out of scope here).
- **Scope boundary**: no changes to `engine_fx.c`, `engine.c`, `delay/`, or
  any other VST3 plugin. Delay has the identical bug but is a separate,
  independently tracked finding out of scope for this fix.

## Open Questions

None blocking — this is a narrow, structural mirror of an already-shipped,
already-tested pattern in the same codebase (Reverb). No live user was
available to interactively confirm scope during this brainstorm; the
assumptions above (keep `kEchoCapFrames` as the default/initial value rather
than deleting it, create a new wrapper test file since none exists, and
update the one dependent test-harness file as a direct, unavoidable
consequence of the fix rather than scope creep) are the only judgment calls
made autonomously, and are documented here for review.
