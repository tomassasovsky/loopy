# Contributing to Loopy

## Start here
Read **`docs/PROGRESS.md`** — it's the living source of truth for what's built,
the build/test gotchas, the locked design decisions, and the roadmap. The
original design is in `docs/plan/`.

## Keep PROGRESS.md current (important)
When a piece of work lands, **update `docs/PROGRESS.md`** in the same change:
move the item from **Roadmap → Done** and bump the "last green" test counts.
This is how progress survives across sessions — treat it as part of "done".

## Running tests
The native engine is the real-time-critical core; it has **deterministic,
device-free tests** that are the primary safety net (the audio thread can't be
runtime-validated in CI). Build & run them with
`bash packages/loopy_engine/src/test/run_native_tests.sh` (documented in
`docs/PROGRESS.md`). After changing `packages/loopy_engine/src/loopy_engine_api.h`,
regenerate bindings: `dart run ffigen --config ffigen.yaml`.

Every state-management unit, repository, and view also has Dart tests. Run the
full suite per package. (See `docs/PROGRESS.md` for the exact commands and the
test-runner note for this environment.)

## Layering
Strict VGV layering: presentation → bloc → repository → data. Presentation never
imports a data client directly; the engine's `AudioEngine` interface is the test
seam (inject a fake). New work gets tests alongside it.
