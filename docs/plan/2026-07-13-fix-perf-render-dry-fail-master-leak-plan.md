---
title: Dry-stem write failure still lets wet content into master.wav
type: fix
date: 2026-07-13
---

## Dry-stem write failure still lets wet content into master.wav - Minimal

In the offline performance-render worker (`le_pr_worker_main` in
`packages/loopy_engine/src/core/perf_render.c`, ~line 1053-1087), the
per-channel `ok` flag is seeded from the DRY stem's write-to-disk result. If
that write fails (e.g. transient I/O error) but the in-memory `stem` buffer
is still valid, the code proceeds to render and write the WET stem from that
same buffer. The master-accumulation gate only tests `wet_ok`, not the
combined `ok` (dry AND wet), so a dry-write failure paired with wet-write
success still sums that channel's wet samples into `master_accum` /
`master.wav` — even though `le_perf_render_track_status` correctly reports
the channel as failed. This breaks the file's own documented invariant that
a consumer checking every track's status has everything it needs to trust
`master.wav`.

Fix: gate the master-accumulation on the channel's combined `ok` (after
`ok = ok && wet_ok`), not `wet_ok` alone. Add a test-only force-dry-write-
failure hook to `perf_render.c` (mirroring the existing
`le_perf_drain_force_write_failure_for_test` pattern in `perf_drain.c` /
`engine_internal.h`) and a regression test proving a dry-fail/wet-succeed
channel is excluded from `master.wav`.

Full design rationale: `docs/brainstorm/2026-07-13-perf-render-dry-fail-master-leak-brainstorm-doc.md`

## Success Criteria

```success-criteria
GOAL: A channel whose dry-stem write fails is never summed into master.wav, even when its wet-stem write succeeds, and this is covered by a deterministic regression test.

SUCCESS CRITERIA:
- The master-accumulation gate in le_pr_worker_main sums a channel into master_accum only when that channel's combined ok (dry write AND wet write both succeeded) is true, not wet_ok alone | verify: grep -n "if (ok && master_accum != NULL)" packages/loopy_engine/src/core/perf_render.c
- The stale comment describing the old wet_ok-only gate is updated to describe the corrected dry-AND-wet gate | verify: manual 1. Open packages/loopy_engine/src/core/perf_render.c 2. Read the comment immediately above the master_accum summation loop inside le_pr_worker_main 3. Confirm it describes both dry-write and wet-write failure modes being excluded from master.wav, not just wet-write failure
- A test-only hook exists to force the dry-stem write in le_pr_worker_main to fail independently of the wet-stem write, declared in engine_internal.h and defined in perf_render.c | verify: grep -n "le_pr_force_dry_write_failure_for_test" packages/loopy_engine/src/core/engine_internal.h packages/loopy_engine/src/core/perf_render.c
- A new regression test in test_engine_core.c drives a render where one channel's dry write is forced to fail while its wet write succeeds, then asserts that channel is reported failed via le_perf_render_track_status AND that master.wav does not contain that channel's contribution | verify: grep -n "test_perf_render_dry_write_fail_excludes_from_master" packages/loopy_engine/src/test/test_engine_core.c
- The full native engine test suite (existing + new test) builds and passes on this machine's toolchain, using the real flutter/native toolchain path per the project's documented test-runner gotcha | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- No other files outside perf_render.c, engine_internal.h, and test_engine_core.c are modified (scope discipline vs. the other 20 parallel fixes in this review pass) | verify: test -z "$(git diff --name-only -- . ':!packages/loopy_engine/src/core/perf_render.c' ':!packages/loopy_engine/src/core/engine_internal.h' ':!packages/loopy_engine/src/test/test_engine_core.c' ':!docs/brainstorm' ':!docs/plan')"

NON-GOALS:
- Do not stop the wet stem from being rendered/written to disk when the dry write has already failed (out of scope: current behavior already writes the wet stem file regardless; only master.wav inclusion is being fixed)
- Do not change le_perf_render_track_status's public semantics or ABI (it already correctly reports ok, which is unchanged)
- Do not touch le_pr_render_track, le_pr_render_wet_track, le_pr_write_wav_mono's internals, or le_pr_render_master
- Do not fix any other finding from the same multi-agent review pass (owned by other parallel worktrees)

VERIFICATION COMMAND: grep -n "if (ok && master_accum != NULL)" packages/loopy_engine/src/core/perf_render.c && grep -n "le_pr_force_dry_write_failure_for_test" packages/loopy_engine/src/core/engine_internal.h packages/loopy_engine/src/core/perf_render.c && grep -n "test_perf_render_dry_write_fail_excludes_from_master" packages/loopy_engine/src/test/test_engine_core.c && bash packages/loopy_engine/src/test/run_native_tests.sh
```

## Context

- File: `packages/loopy_engine/src/core/perf_render.c`, function `le_pr_worker_main`, lines ~1045-1097 (channel loop).
- Current buggy sequence (paraphrased, current line numbers):
  ```c
  int ok = 0;
  if (stem != NULL) {
    ok = le_pr_write_wav_mono(dry_path, stem, ...);   /* DRY write; ok may become 0 here */

    float* wet = le_pr_render_wet_track(..., stem, &wet_failed);
    if (wet != NULL) {
      const int wet_ok = le_pr_write_wav_mono(wet_path, wet, ...);
      ok = ok && wet_ok;                               /* ok now reflects BOTH writes */
      if (wet_ok && master_accum != NULL) {             /* BUG: gates on wet_ok only */
        for (...) master_accum[f] += wet[f];
      }
      free(wet);
    } else {
      ok = 0;
    }
    free(stem);
  }
  ```
- Fix: change `if (wet_ok && master_accum != NULL)` to `if (ok && master_accum != NULL)`. At that point in the function `ok` already equals `dry_ok && wet_ok` (it was reassigned via `ok = ok && wet_ok` on the line immediately above), so this is the minimal one-line condition change matching the issue's suggested fix direction.
- Existing precedent for the test hook pattern to copy: `packages/loopy_engine/src/core/perf_drain.c` lines ~168-172 (`g_pd_force_write_failure` atomic + `le_perf_drain_force_write_failure_for_test`), declared in `packages/loopy_engine/src/core/engine_internal.h:231`, used in `packages/loopy_engine/src/test/test_engine_core.c` around lines 4050, 4064, 4885, 4894 (set to 1 before triggering the failure path, reset to 0 immediately after — always reset even if assertions fail, to avoid poisoning later tests. Consider wrapping the reset in a way that still runs if a CHECK fails, matching however the existing perf_drain tests handle this — read those two call sites in full before writing the new test).
- Existing test to model the new one on (structure, not the failure-injection mechanism): `test_perf_render_partial_success` in `test_engine_core.c` (~line 8412-8473) — shows the manifest/log/dir setup and how to poll for render completion and read per-track status. Also read `test_read_wet_stem` / equivalent for reading `master.wav` (search for how existing wet-pass tests, e.g. `test_perf_render_wet_fx_sweep` ~line 8536, read back rendered wet/master content) to reuse the same WAV-reading test helper for asserting master.wav's contents in the new test.
- Test runner gotcha (per project memory): the very_good MCP test runner is broken for this native C suite; use the documented `bash packages/loopy_engine/src/test/run_native_tests.sh` path directly (absolute flutter path not required here — this is a native gcc/clang test, not a Dart/Flutter test).

## MVP

1. In `perf_render.c`, change the master-accumulation gate from `wet_ok` to `ok` (post-update), and correct the adjacent comment to describe both failure modes.
2. In `perf_render.c` + `engine_internal.h`, add a test-only `_Atomic int g_pr_force_dry_write_failure` flag (relaxed memory order, mirroring `g_pd_force_write_failure`) and a public `le_pr_force_dry_write_failure_for_test(int enabled)` setter, declared in `engine_internal.h` with a "not part of the FFI surface" comment matching the drain hook's. Document it as process-global/must-be-reset, same caveat as the drain hook. Committed design (single approach, no alternatives): check the flag right after computing `dry_path`, before calling `le_pr_write_wav_mono(dry_path, ...)` — if set, short-circuit `ok = 0` without calling the real write function or touching the filesystem at all; otherwise call `le_pr_write_wav_mono` as today. This leaves the wet-write path completely untouched, so it can succeed independently.
3. In `test_engine_core.c`, add `test_perf_render_dry_write_fail_excludes_from_master`, registered as a flat call in the test list immediately after `test_perf_render_wet_fx_sweep()`. **Implementation deviation from the original two-channel sketch**: the chosen hook design (a single process-global flag checked at the dry-write call site, mirroring `perf_drain.c`'s blanket `g_pd_force_write_failure` exactly) fails every channel's dry write uniformly for the render's duration — it has no per-channel selectivity, matching the existing precedent's own shape rather than inventing a more granular (and more complex) hook. A single-channel manifest is therefore sufficient and simpler: force the one channel's dry write to fail, assert (a) `le_perf_render_track_status` reports it failed, (b) the wet stem file on disk still contains real, correct content (proving the wet write genuinely succeeded, not skipped), and (c) `master.wav` is all-zero (proving the channel's wet content was excluded from the sum). This isolates and directly reproduces the exact bug scenario without needing a second channel — the complementary invariant ("a normally-succeeding channel's own contribution still lands in master.wav") is already covered by existing tests (`test_perf_render_wet_fx_sweep`, `test_perf_render_golden_master_parity`), so re-proving it here would be redundant. Call `le_pr_force_dry_write_failure_for_test(1)` before `le_perf_render_begin`, and reset to `0` immediately after polling for `done` (before any `CHECK` calls, matching the existing precedent's ordering at lines ~4050-4064, keeping the flag from leaking into later tests regardless of assertion outcome).
4. Run `bash packages/loopy_engine/src/test/run_native_tests.sh` and confirm "ALL PASSED" twice (per the script's own header comment) with the new test included.

## References

- Brainstorm doc: `docs/brainstorm/2026-07-13-perf-render-dry-fail-master-leak-brainstorm-doc.md`
- Issue evidence file: `packages/loopy_engine/src/core/perf_render.c` (`le_pr_worker_main`, ~line 1053-1087)
- Precedent pattern: `packages/loopy_engine/src/core/perf_drain.c` (~line 168-172), `packages/loopy_engine/src/core/engine_internal.h:231`
- Test runner: `packages/loopy_engine/src/test/run_native_tests.sh`
