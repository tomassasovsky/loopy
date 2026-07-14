---
date: 2026-07-13
topic: perf-render-dry-fail-master-leak
---

# Fix: dry-stem write failure still leaks wet content into master.wav

## What We're Building

In `packages/loopy_engine/src/core/perf_render.c`'s `le_pr_worker_main`
(~line 1053-1087), the offline performance-render worker seeds a per-channel
`ok` flag from the DRY stem's write-to-disk result. If the dry write fails
(e.g. a transient I/O error) but the in-memory `stem` buffer is still valid,
the code still renders and writes the WET stem from that same buffer. The
gate that sums a channel's wet samples into `master_accum` (which becomes
`master.wav`) only checks `wet_ok`, not the combined `ok` (dry AND wet). So a
dry-write failure paired with a wet-write success still bakes that channel's
audio into `master.wav`, even though `le_perf_render_track_status` correctly
reports the channel as failed (`ok = ok && wet_ok` stays 0 because the
original `ok` was already 0).

The fix: change the master-accumulation gate from `if (wet_ok && master_accum
!= NULL)` to `if (ok && master_accum != NULL)`, evaluated after `ok` has been
updated to reflect both writes (`ok = ok && wet_ok`). This restores the
documented invariant in the surrounding comment: a consumer that checks every
track's status before trusting `master.wav` has everything it needs, because
a failed channel (dry OR wet write failure) never contributes to the master
sum.

## Why This Approach

This is a single-line boolean-condition fix at the exact site the finding
already identified — no restructuring of `le_pr_worker_main`'s control flow,
no change to write ordering, no change to the public ABI
(`le_perf_render_track_status` semantics are unchanged: it already reports
`ok`, which already accounts for both writes). Alternative approaches
considered and rejected:

- **Skip the wet render/write entirely once the dry write fails.** This
  would change behavior beyond the reported bug (currently a failed dry
  write does NOT stop the wet stem file itself from being written to disk
  — only the master accumulation is wrong). Changing that too is out of
  scope for this narrowly-targeted fix and could interact with other
  reviewers' parallel work on this same file.
- **Add a separate `dry_ok` local and gate on `dry_ok && wet_ok`.** Equivalent
  in effect to gating on `ok` after the `ok = ok && wet_ok` update, but
  introduces a redundant variable. Simpler to just reuse `ok`, which already
  holds exactly that combined value by the time the gate is checked.

The chosen approach is the minimal, mechanically obvious fix matching the
issue's own suggested fix direction.

## Key Decisions

- **Gate on `ok` (post `ok = ok && wet_ok` update), not a new variable.**
  `ok` at that point in the function already equals `dry_ok && wet_ok`
  (`ok` was seeded from the dry write result, then combined with `wet_ok`
  via `ok = ok && wet_ok` immediately before the gate). Reusing it is the
  smallest possible diff and keeps `ok`'s meaning ("this channel is trustworthy
  end-to-end") consistent with what's stored in `r->results[index].succeeded`.
- **Do not change the wet-write behavior when the dry write already failed.**
  The wet stem file on disk is left as-is (still written) if the wet write
  itself succeeds; only whether it's *summed into master* changes. This
  matches the issue's precise scope — the bug is specifically about
  `master.wav` contamination, not about whether individual wet stem files
  get written.
- **Update the stale comment above the gate.** The existing comment says "A
  wet-write failure ... leaves that channel out of the master sum below" —
  this needs to be corrected/extended to describe both failure modes now
  that the gate checks `ok` instead of `wet_ok` alone, so the comment stays
  accurate and doesn't mislead the next reader.
- **Add a regression test** in
  `packages/loopy_engine/src/test/test_engine_core.c` that forces a dry-write
  failure while keeping the wet write successful, then asserts (a) the
  channel is reported as failed via `le_perf_render_track_status`, and (b)
  `master.wav` does NOT contain that channel's contribution (only other,
  successful channels' contributions are present, or master is all-zero if
  it's the only channel). The existing
  `test_perf_render_partial_success` test forces failure via a missing
  source WAV, which fails inside `le_pr_render_track` (stem == NULL) before
  reaching the dry/wet split at all — it does not exercise this code path.
  A new test is needed that keeps `stem != NULL` (so rendering proceeds)
  but makes only the dry write fail.
  **Confirmed existing precedent**: `perf_drain.c` already has exactly this
  shape of test hook — a `static _Atomic int g_pd_force_write_failure`
  flipped by a test-only `le_perf_drain_force_write_failure_for_test(int)`
  function (declared in `engine_internal.h`, defined in `perf_drain.c`,
  called directly from `test_engine_core.c`, e.g. around line 4050 and
  4885). `perf_render.c` has no equivalent today. Following this
  established pattern: add a small test-only hook to `perf_render.c` —
  a static atomic flag plus a `le_pr_force_dry_write_failure_for_test(int
  enabled)` setter (declared in `engine_internal.h`) — checked only at the
  DRY write call site (`ok = le_pr_write_wav_mono(dry_path, ...)`), leaving
  the wet write path unaffected so it can succeed independently. This is
  deterministic, portable, and consistent with how this codebase already
  simulates write failures elsewhere, rather than relying on OS-specific
  `fopen`-on-a-directory behavior.
- **Scope discipline.** No other findings from the same review pass are
  touched. No refactor of `le_pr_worker_main` beyond the single gate
  condition (and its adjacent comment). No changes to `le_pr_render_track`,
  `le_pr_render_wet_track`, `le_pr_write_wav_mono`, or `le_pr_render_master`.

## Open Questions

None blocking — proceeding autonomously per instructions. Confirmed by
inspection: `perf_drain.c` / `engine_internal.h` / `test_engine_core.c`
already establish the force-write-failure test-hook pattern this fix will
mirror for `perf_render.c`'s dry-write path (see Key Decisions above), so no
further research is needed before planning.
