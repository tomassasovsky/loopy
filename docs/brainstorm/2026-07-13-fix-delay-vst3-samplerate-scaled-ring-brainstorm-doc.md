---
date: 2026-07-13
topic: fix-delay-vst3-samplerate-scaled-ring
---

# Fix: Loopy Delay VST3 delay-ring capacity doesn't scale with host sample rate

## What We're Building

`packages/loopy_engine/vst3/delay/processor.h` hardcodes
`static constexpr int kDelayCapFrames = 48000;` and the Delay processor has no
`setupProcessing()` override, so the delay-ring capacity never adapts to the
host's negotiated sample rate. `fx_delay`'s normalized "Time" parameter maps
directly onto this cap in samples (`engine_fx.c`), so at any sample rate other
than 48 kHz the plugin's actual max delay time diverges from the live engine
(`engine.c`: `fx_delay_frames = sample_rate`) and from the same normalized
value at a different sample rate — e.g. at 96 kHz max delay is 0.5 s instead
of 1 s; at 44.1 kHz it's ~1.088 s instead of 1 s.

The sibling Reverb VST3 plugin (`packages/loopy_engine/vst3/reverb/`) already
solves exactly this problem: it has a `setupProcessing()` override, a `cap_`
member recomputed from `processSetup.sampleRate`, a public static
`computeRingCapacity(double sampleRate)` helper, and a
`ringCapacityForTesting()` accessor used by its own 96 kHz regression test.

This fix mirrors Reverb's proven pattern onto Delay: move ring sizing out of
`initialize()` and into `setupProcessing()`, size it to the real negotiated
sample rate, and add the same testing hooks plus a sample-rate regression
test.

## Why This Approach

**Mirror Reverb exactly (chosen).** Reverb already solved this identical
problem in the same codebase, using the same underlying `engine_fx.h` seam
(`le_fx_prepare` / `fx_apply_chain`). Delay's `fx_delay` (`engine_fx.c`) already
guards `buf == NULL` safely (dry passthrough), the same guard `fx_reverb` relies
on before its ring is first sized in `setupProcessing()` — so the same
lazy-allocate-on-setupProcessing structure is safe to reuse verbatim. Doing
anything else (e.g. a Delay-specific formula, or scaling in `process()` per
block) would introduce a second, divergent pattern for solving the same
problem the codebase already has one answer for.

Two alternatives were considered and rejected:

- **Recompute the cap inside `process()` from `processSetup.sampleRate` every
  block, without a `setupProcessing()` override.** Rejected: `processSetup` is
  only refreshed by `setupProcessing()`; reading it in `process()` without ever
  overriding the callback still leaves the ring sized however `initialize()`
  left it. It also reallocates on a hot path unless you add the same
  "only reallocate if changed" cap-diffing that `setupProcessing()` gives you
  for free, once per rate change instead of once per block. No advantage over
  mirroring Reverb, and it's a new pattern instead of a proven one.
- **Keep the fixed 48000 cap but rescale the Time parameter's mapping by
  `sampleRate / 48000` inside `fx_delay`/`engine_fx.c` instead of resizing the
  ring.** Rejected: `engine_fx.c` is the shared DSP core used by the live
  engine and every other FX wrapper (Echo also uses `fx_stereo_ring_prepare`);
  changing its param-to-samples mapping would be a much larger blast radius
  than fixing one VST3 wrapper's ring sizing, and it still wouldn't fix the
  actual bug (a ring that's too small for the sample rate silently truncates
  at the top of the delay range — same failure Reverb's fixed-cap-comment
  documents for its own comb/allpass network).

## Key Decisions

- **Move `le_fx_prepare` from `initialize()` to `setupProcessing()`,
  matching Reverb's structure verbatim.** `initialize()` no longer prepares the
  ring; `setupProcessing()` computes the new cap, frees the old ring only if
  the cap changed (`fx_alloc_ring` only allocates when the pointer is `NULL`),
  and calls `le_fx_prepare` with the new cap. Before the first `setupProcessing()`
  call, `fx_.delay[0][0]` is `NULL` and `fx_delay`'s own `buf == NULL` guard
  makes `process()` a safe dry passthrough — exactly Reverb's documented
  behavior.
- **Keep `kDelayCapFrames` as a named constant, repurposed as `cap_`'s initial
  value (48000), not removed.** Unlike Reverb (which has no such constant),
  Delay's `kDelayCapFrames` is referenced outside `delay/`: `vst3/test/test_delay_parity.cpp`
  and a comment in `vst3/test/host_harness.h`. Removing it would break the
  build. Its doc comment must be corrected to drop the "not something this
  wrapper adjusts, D-SEAM scope" framing (per the issue: the repo owner has
  decided this should scale, overriding that comment's prior stance) and
  instead describe it as the pre-`setupProcessing()` default / initial
  allocation size, matching `cap_`'s own default-value framing in Reverb's
  header.
- **Add `computeRingCapacity(double sampleRate)` as a public static method,
  identical formula to Reverb's (`round(sampleRate)`, floor of 1).** This is
  the one used by both `setupProcessing()` and (after this fix) the golden-parity
  harness's `computeCap` — same reasoning Reverb already established: a single
  source of truth the harness references instead of re-deriving.
- **Add `ringCapacityForTesting()` accessor and a `cap_` member**, mirroring
  Reverb's header exactly, so a new wrapper test can assert the ring size
  itself (not just "produces non-silent output," which a truncated ring would
  also do).
- **Update `test_vst3_delay_wrapper.cpp`** with a sample-rate regression test
  mirroring Reverb's `test_reverb_stays_correct_at_96khz` — asserting
  `ringCapacityForTesting()` scales at 96 kHz (and add a `setupProcessing48k`
  helper the way Reverb's test file has one, since `initialize()` no longer
  prepares the ring — needed by the existing `test_processor_param_round_trip`
  test too once the ring is no longer prepared eagerly in `initialize()`, to
  keep DSP-touching tests meaningful, even though that specific test doesn't
  strictly require a live ring to pass since it only checks queued-param
  storage).
- **Update `vst3/test/test_delay_parity.cpp`'s `computeCap` lambda** from the
  fixed `kDelayCapFrames` literal to `&loopy_vst3_delay::Processor::computeRingCapacity`,
  matching how `test_reverb_parity.cpp` already wires its own `computeCap`.
  This is required for the golden-parity harness to keep passing at
  non-48kHz rates in its existing `{44100, 48000, 88200, 96000}` sweep — once
  the hosted path's real cap scales with sample rate, the harness's
  direct-`fx_apply_chain` reference must use the same scaled cap or a cap
  mismatch alone (not a real bug) would fail the diff.
- **Update the stale comment in `vst3/test/host_harness.h`** (currently reads
  "Delay uses a fixed 48000 regardless of sr ... Reverb scales with sr") to
  reflect that both plugins now scale with sample rate via their own
  `computeRingCapacity`.
- **Scope boundary**: no changes to `engine_fx.c`, `engine.c`, or any other
  VST3 plugin (Echo/Tremolo/Octaver/Filter/Drive) — those are out of scope for
  this issue and are covered (or not) by other, independent findings in the
  same review pass.

## Open Questions

None blocking — this is a narrow, structural mirror of an already-shipped,
already-tested pattern in the same codebase (Reverb, part 3 of the same
umbrella plan). No live user was available to interactively confirm scope
during this brainstorm; the assumptions above (keep `kDelayCapFrames` as the
default/initial value rather than deleting it, and update the two dependent
test-harness files as a direct, unavoidable consequence of the fix rather than
scope creep) are the only judgment calls made autonomously, and are
documented here for review.
