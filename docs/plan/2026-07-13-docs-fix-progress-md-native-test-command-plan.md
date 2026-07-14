---
date: 2026-07-13
type: docs
topic: fix-progress-md-native-test-command
brainstorm: docs/brainstorm/2026-07-13-fix-progress-md-native-test-command-brainstorm-doc.md
---

# docs: fix stale native-test build command in PROGRESS.md

## Summary

`docs/PROGRESS.md`'s "Native engine tests" bullet (~lines 26-37) documents a
flat `clang` invocation against source paths (`src/engine.c`,
`src/lockfree_ring.c`, `src/loop_clock.c`, `src/miniaudio_impl.c`,
`src/engine_miniaudio.c`, `src/engine_linux.c`, `src/engine_apple.c`,
`src/engine_windows.c`, `-I src -I src/miniaudio`) that no longer exist —
the engine's `src/` tree was reorganized into `src/core/`, `src/platform/`,
`src/asio/`, `src/midi/`, `src/miniaudio/` subdirectories with many more
split translation units. Running the documented command fails immediately.

The correct, currently-working entry point already exists:
`bash packages/loopy_engine/src/test/run_native_tests.sh` (documented
accurately in `packages/loopy_engine/README.md`'s "Run the native core
tests" section). This is a docs-only fix, scoped to two files:
`docs/PROGRESS.md` and `CONTRIBUTING.md`.

This plan is **Minimal** detail level: a straightforward, low-risk text
replacement in two markdown files, no code/tests/architecture involved.

## Scope

**In scope:**
- Replace the stale clang command block in `docs/PROGRESS.md` (~lines 26-37)
  with an accurate pointer to `run_native_tests.sh`.
- Update `CONTRIBUTING.md`'s "Running tests" section (lines 13-19) so its
  reference to "the command in `docs/PROGRESS.md`" still reads correctly
  once PROGRESS.md no longer contains a literal clang invocation.

**Out of scope (explicitly not touched):**
- `packages/loopy_engine/README.md` — already correct, not part of this fix.
- Any other findings from the same review pass (other agents own those).
- Any source/test code.

## Implementation

### File 1: `docs/PROGRESS.md`

Replace the existing fenced block:

```sh
cd packages/loopy_engine
clang -std=c11 -Wall -Wextra -I src -I src/miniaudio \
  src/test/test_engine_core.c src/engine.c src/lockfree_ring.c \
  src/loop_clock.c src/miniaudio_impl.c src/engine_miniaudio.c \
  src/engine_linux.c src/engine_apple.c src/engine_windows.c \
  -framework CoreAudio -framework AudioToolbox -framework AudioUnit \
  -framework CoreFoundation -lpthread -lm -o /tmp/loopy_core_tests
/tmp/loopy_core_tests
```

with a corrected block that:
1. Points at `bash packages/loopy_engine/src/test/run_native_tests.sh` (run
   from repo root — the script self-locates via `$(dirname "$0")`, so no
   preceding `cd` is required).
2. Briefly describes what it builds/runs: the engine core test suite and
   the MIDI test suite on every desktop OS (gcc/gnu11 by default,
   overridable via `CC`), plus macOS-only plugin scan/slot native tests
   against the vendored VST3/CLAP SDKs.
3. States the pass condition: each suite prints "ALL PASSED"; the script
   exits non-zero on any failure.

Keep the same bullet position/heading ("Native engine tests") and the same
one-sentence lead-in ("deterministic, no device — the real safety net since
the audio thread can't be runtime-tested here").

### File 2: `CONTRIBUTING.md`

In the "Running tests" section, replace:

> Build & run them with `clang` (command in `docs/PROGRESS.md`).

with wording that references the actual command directly, e.g.:

> Build & run them with `bash packages/loopy_engine/src/test/run_native_tests.sh`
> (documented in `docs/PROGRESS.md`).

Keep the rest of the paragraph (the ffigen regen instruction that follows)
unchanged.

## Files Changed

- [ ] `docs/PROGRESS.md` — replace stale clang command block (~lines 26-37)
- [ ] `CONTRIBUTING.md` — update "Running tests" wording (~lines 13-19)

## Success Criteria

```yaml
success-criteria:
  - criterion: docs/PROGRESS.md no longer references any of the stale flat
      source paths (src/engine.c, src/lockfree_ring.c, src/loop_clock.c,
      src/miniaudio_impl.c, src/engine_miniaudio.c, src/engine_linux.c,
      src/engine_apple.c, src/engine_windows.c) or the bare `-I src -I
      src/miniaudio` include flags in the native-test command.
    verify: "! grep -E 'src/engine\\.c|src/lockfree_ring\\.c|src/engine_miniaudio\\.c|-I src -I src/miniaudio' docs/PROGRESS.md"
  - criterion: docs/PROGRESS.md documents the correct working command.
    verify: "grep -q 'run_native_tests.sh' docs/PROGRESS.md"
  - criterion: The referenced script path actually exists in the repo (so
      the new pointer is not itself stale).
    verify: "test -x packages/loopy_engine/src/test/run_native_tests.sh || test -f packages/loopy_engine/src/test/run_native_tests.sh"
  - criterion: CONTRIBUTING.md points at the same corrected command rather
      than the old "clang (command in docs/PROGRESS.md)" phrasing.
    verify: "grep -q 'run_native_tests.sh' CONTRIBUTING.md"
  - criterion: Only the two intended files are touched (docs-only, narrowly
      scoped change — no source/test/other doc files modified).
    verify: "manual: run `git diff --stat` against the base branch and confirm the only changed paths are docs/PROGRESS.md and CONTRIBUTING.md (plus the new docs/brainstorm and docs/plan files this process itself adds)."
  - criterion: Markdown renders cleanly — fenced code blocks properly
      closed, no broken heading structure introduced by the edit.
    verify: "manual: visually inspect the diff hunk in docs/PROGRESS.md and CONTRIBUTING.md for balanced triple-backtick fences and correct list/heading nesting."
```

## Risks / Notes

- Purely additive/corrective text change; no runtime behavior affected.
- Low risk of merge conflict since both target files are being edited by
  many parallel agents in this review-pass fan-out — keep the diff minimal
  and localized to the exact stale lines to reduce collision surface.
