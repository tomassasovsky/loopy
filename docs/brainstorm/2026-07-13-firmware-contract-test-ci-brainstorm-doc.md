---
date: 2026-07-13
topic: firmware-contract-test-ci
---

# Wire the firmware/Dart protocol contract test into CI

## What We're Building

`firmware/test/test_pedal_protocol.c` is the only thing that proves the AVR
firmware's `pedal_protocol.c` and Dart's `PedalCodec`
(`packages/pedal_repository`) agree byte-for-byte on the SysEx wire format. It
compiles on the host (no board), links `firmware/loopy_pedal/pedal_protocol.c`,
and decodes/re-encodes the same golden `.syx` fixtures
`packages/pedal_repository/test` uses.

Its own file header claims: "No board required — runs in CI exactly like the
engine's native MIDI suite." That's false today — `.github/workflows/main.yaml`
has zero references to `firmware/` anywhere (confirmed via
`grep -rn "firmware" .github/workflows/`), so a change that breaks
firmware/Dart parity would merge silently.

This fix adds a step to the existing `native-tests` job in
`.github/workflows/main.yaml` (already `ubuntu-latest` with
`build-essential` installed) that builds and runs
`firmware/test/test_pedal_protocol.c` using the exact `gcc` command documented
in `firmware/README.md`'s "Contract test (host, no board)" section, immediately
after the engine/MIDI suite step it claims parity with. It also tightens the
misleading header comment now that it will actually be true.

## Why This Approach

**Chosen: new step in the existing `native-tests` job, invoked directly (not
routed through `run_native_tests.sh`).**

- `run_native_tests.sh` opens with `cd "$(dirname "$0")/../.."`, which lands it
  in `packages/loopy_engine` — a different working directory than the firmware
  test needs. The firmware README is explicit that the contract test must run
  "from the repo root, so the default fixtures path resolves"
  (`packages/pedal_repository/test/fixtures`, a relative default baked into
  `test_pedal_protocol.c`). Forcing it into `run_native_tests.sh`'s directory
  convention means either passing the fixtures path explicitly or doing
  fragile relative `cd`s back out — more moving parts for no benefit.
- The job comment directly above `native-tests` in `main.yaml`
  ("`run_native_tests.sh` builds and runs both suites") would become stale/
  inaccurate the moment a third suite is folded into that script, requiring an
  edit anyway — so there's no real savings from cramming it into the script.
- A GitHub Actions job step is already the natural unit for "one buildable,
  runnable thing" — adding a sibling `- name: ... / run: ...` step under
  `native-tests` mirrors how `vst3-plugins-*` jobs lay out multiple discrete
  build+test actions, and is the literal ask in the issue's suggested fix
  direction ("just a new step in the existing one").
- No new job is needed: `native-tests` already provisions `build-essential`
  (gcc) and runs on `ubuntu-latest`; the firmware contract test needs nothing
  else (no ALSA, no board, no Arduino toolchain — only `pedal_protocol.c` +
  `pedal_protocol.h`).

**Rejected alternative: fold into `run_native_tests.sh` as a third suite.**
Would require the script to `cd` back to repo root (or pass an explicit
fixtures argument) partway through, breaking its current "one `cd` at the top,
everything relative after" structure, and would still require updating the
script's own header comment and the `native-tests` job comment in `main.yaml`.
Same end result, more edited surface area, higher risk of an accidental path
bug in a script that other suites also depend on.

**Rejected alternative: new standalone CI job (e.g. `firmware-contract-test`).**
The issue explicitly says this doesn't need a new job. A whole job adds
scheduling/concurrency overhead for what's a ~1-second gcc compile + binary
run; a step is proportionate.

## Key Decisions

- **Where**: add the step inside the `native-tests` job in
  `.github/workflows/main.yaml`, after the existing "Build + run native
  engine/MIDI tests" step. Working directory is the checkout root by default
  in GitHub Actions, matching what the README's command requires.
- **Exact command**: reuse verbatim the command already documented in
  `firmware/README.md`:
  ```sh
  gcc -std=c11 -Wall -I firmware/loopy_pedal \
    firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c \
    -o pedal_protocol_tests && ./pedal_protocol_tests
  ```
  Reusing the documented command (rather than inventing a new invocation)
  keeps the README and CI from drifting apart the way the CI gap itself arose.
- **No new dependencies to install**: `native-tests`' existing
  `build-essential` install already provides `gcc`; the firmware test needs no
  ALSA/CoreMIDI/etc (it only links the pure-C codec unit).
- **Fixture path**: rely on the test binary's built-in default
  (`packages/pedal_repository/test/fixtures`), which resolves correctly
  because Actions' default working directory for `run:` steps is the repo
  root — no extra argument needed.
- **Header comment fix**: `test_pedal_protocol.c`'s header currently reads "No
  board required — runs in CI exactly like the engine's native MIDI suite."
  Once wired in, this becomes literally true, so leave the *substance* of the
  claim but tighten the wording only if it reads as inaccurate in the interim
  (e.g. drop "exactly like" if the invocation ends up looking meaningfully
  different) — otherwise leave the comment as-is since it will now be
  accurate. Decided during planning: keep the comment's claim, only touch
  wording if the actual CI step name/phrasing warrants a cross-reference.
- **Job comment nearby**: the `native-tests` job's block comment in
  `main.yaml` currently says "run_native_tests.sh builds and runs both
  suites." Since a third, separately-invoked suite is being added to the same
  job (not the script), this comment needs a small update so it doesn't go
  stale itself — e.g. "run_native_tests.sh builds and runs the engine/MIDI
  suites; a third step below builds and runs the firmware contract test."
- **Scope discipline**: no changes to `run_native_tests.sh`, no changes to any
  other CI job, no changes to `pedal_protocol.c`/`pedal_protocol.h`/
  `PedalCodec` themselves, no new fixtures. This is a test-wiring-only fix.

## Assumptions (made autonomously — no live user in this run)

- Assumed `-Wall` should be included in the CI invocation since it's already
  part of the documented/canonical command in the README — consistency over
  inventing a stricter or looser flag set.
- Assumed the step should hard-fail the job on any `CHECK` failure or non-zero
  exit, same as the engine/MIDI suite already does (no `continue-on-error`) —
  this is supposed to be a golden gate, not advisory.
- Assumed no artifact upload / retention is needed for the compiled test
  binary — it's a throwaway host binary, consistent with how the engine/MIDI
  test binaries in `run_native_tests.sh` are also not retained.

## Open Questions

- None blocking. If the repo owner wants this folded into
  `run_native_tests.sh` instead for consistency with the other native suites,
  that's a straightforward follow-up refactor, but the step-based approach
  above satisfies the issue as written with the smallest, lowest-risk diff.
