---
date: 2026-07-13
topic: fix-progress-md-native-test-command
---

# Fix stale native-test build command in docs/PROGRESS.md

## What We're Building

`docs/PROGRESS.md`'s "Native engine tests" section (~line 26-37) documents a
flat `clang` command that compiles source paths (`src/engine.c`,
`src/lockfree_ring.c`, `src/loop_clock.c`, `src/miniaudio_impl.c`,
`src/engine_miniaudio.c`, `src/engine_linux.c`, `src/engine_apple.c`,
`src/engine_windows.c`) with `-I src -I src/miniaudio`. None of these flat
paths exist anymore — the engine's `src/` tree was reorganized into
`src/core/`, `src/platform/`, `src/asio/`, `src/midi/`, `src/miniaudio/`
subdirectories, and the C files were split into many more translation units.
Running the documented command fails immediately with "No such file or
directory".

The correct, currently-working entry point already exists and is documented
in `packages/loopy_engine/README.md`: `bash
packages/loopy_engine/src/test/run_native_tests.sh`. This brainstorm scopes a
docs-only fix: replace the stale command in `docs/PROGRESS.md` with an
accurate description of and pointer to that script, and fix
`CONTRIBUTING.md`'s reference (which currently says "Build & run them with
`clang` (command in `docs/PROGRESS.md`)") so it doesn't perpetuate the stale
pointer.

No source code changes. No test changes. Two markdown files touched:
`docs/PROGRESS.md` and `CONTRIBUTING.md`.

## Why This Approach

Read `packages/loopy_engine/src/test/run_native_tests.sh` in full to describe
it accurately rather than guessing. Key facts confirmed by reading the
script:

- It `cd`s to `packages/loopy_engine` itself (`cd
  "$(dirname "$0")/../.."`), so the documented invocation only needs `bash
  packages/loopy_engine/src/test/run_native_tests.sh` from the repo root — no
  extra `cd` step required first (simpler than the old doc's `cd
  packages/loopy_engine` + inline clang invocation).
- Default compiler is `gcc` (`CC="${CC:-gcc}"`), overridable via the `CC` env
  var; uses `-std=gnu11` (not strict c11 — needed for POSIX symbols on
  Linux). `CXX` (default `clang++`) is used for the macOS-only plugin
  sections.
- It builds and runs, in order: (1) the engine core test suite
  (`test_engine_core.c` + globbed `src/core/engine*.c` + ring/clock/audio
  primitives + `src/platform/engine_*.c` + `src/miniaudio/miniaudio_impl.c`),
  (2) the MIDI test suite (`test_midi_core.c` + `src/midi/*.c`), and (3),
  **macOS only**, plugin-scan and plugin-slot native tests against the
  vendored VST3/CLAP SDKs (`third_party/vst3sdk`, `third_party/clap`) — these
  are skipped entirely on Linux/Windows pending later ports.
- Each suite must print "ALL PASSED"; the script exits non-zero (via `set
  -euo pipefail`) on any compile or test failure.
- Per-OS library flags are handled inside the script (CoreAudio/CoreMIDI
  frameworks on Darwin, ALSA on Linux, `ole32`/`winmm` on Windows) — the
  contributor doesn't need to know these details, which is itself an
  improvement over the old doc that hardcoded macOS-only `-framework` flags
  as if they applied everywhere.

Given this, the fix is a straight **replace-in-place**: swap the entire
fenced code block (`cd packages/loopy_engine` + multi-line `clang` command +
`/tmp/loopy_core_tests`) for a single `bash
packages/loopy_engine/src/test/run_native_tests.sh` command, plus 2-3
sentences of prose describing what it covers (engine + MIDI always; plugin
scan/slot on macOS only) and what to expect ("ALL PASSED" per suite). This
keeps the same doc location/heading/tone ("Native engine tests" bullet under
"How to build / test") and doesn't restructure surrounding content.

Alternatives considered and rejected:

- **Inline a corrected flat clang command in PROGRESS.md instead of pointing
  at the script.** Rejected: this would duplicate the source list that
  `run_native_tests.sh` already globs and keeps in sync with
  `src/CMakeLists.txt` (per the script's own header comment: "The engine
  source list MUST match src/CMakeLists.txt's add_library list ... Keep them
  in sync"). Duplicating it in PROGRESS.md would just recreate the same
  drift risk this bug report is about — a second copy of a list that changes
  whenever a TU is split/added/renamed. Pointing at the script is the only
  fix that can't go stale the same way again.
- **Only fix PROGRESS.md, leave CONTRIBUTING.md's phrasing alone.**
  Rejected: CONTRIBUTING.md's line 16-17 explicitly says "command in
  docs/PROGRESS.md" — if PROGRESS.md's own prose no longer centers on a
  literal "the command", that phrasing needs a small adjustment so it still
  reads correctly and doesn't imply a specific clang invocation lives there.
  The issue report explicitly calls this out as in-scope.
- **Move the native-test instructions out of PROGRESS.md entirely and just
  say "see packages/loopy_engine/README.md".** Rejected as unnecessary
  restructuring: PROGRESS.md's whole "How to build / test" section exists
  precisely so a contributor never has to go hunting across files for
  environment gotchas ("Update this as work lands so any session ... can
  resume cold" per its own intro). Keeping a short, accurate command inline
  (with the README as the fuller reference for what the script does) matches
  the existing pattern used by the other bullets in that section (e.g. the
  FFI-bindings-regen bullet gives the command directly, not just a pointer).

## Key Decisions

- **Replace, don't append**: the stale `cd` + `clang` fenced block in
  `docs/PROGRESS.md` is fully replaced by `bash
  packages/loopy_engine/src/test/run_native_tests.sh` (run from repo root,
  since the script self-`cd`s) plus 2-3 sentences describing coverage
  (engine + MIDI on all OSes; plugin scan/slot macOS-only) and the
  "ALL PASSED" expectation. No other content in that bullet list changes.
- **CONTRIBUTING.md gets a matching, minimal edit**: change "Build & run them
  with `clang` (command in `docs/PROGRESS.md`)" to reference the script
  command directly (e.g. "Build & run them with `bash
  packages/loopy_engine/src/test/run_native_tests.sh` (documented in
  `docs/PROGRESS.md`)"), preserving the existing sentence structure and its
  pointer back to PROGRESS.md as the fuller reference.
- **No changes to `packages/loopy_engine/README.md`**: it already documents
  the script correctly (`src/test/run_native_tests.sh` run from inside
  `packages/loopy_engine`); it is out of scope and not broken.
- **Scope stays docs-only**: no source/test files touched, matching the
  issue's `docs-drift` category and the parallel-worktree instruction to
  stay narrowly scoped to this one finding.

## Open Questions

None blocking — proceeding autonomously per the parent task's instruction
(no live user in this run). One judgment call made without confirmation:
whether to give the exact relative path from repo root or from
`packages/loopy_engine`. Decision: document the repo-root-relative form
(`bash packages/loopy_engine/src/test/run_native_tests.sh`) since
PROGRESS.md's surrounding bullets (e.g. the ffigen one) use `cd
packages/loopy_engine` first — but the script doesn't require that `cd`
(it self-locates via `$(dirname "$0")`), so giving the single-line
repo-root form is simpler and just as correct; this will be called out
explicitly in the doc edit so it doesn't read as inconsistent with the
neighboring bullets that do `cd` first.
