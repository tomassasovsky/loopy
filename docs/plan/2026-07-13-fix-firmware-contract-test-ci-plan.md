---
title: Wire the firmware/Dart protocol contract test into CI
type: fix
date: 2026-07-13
---

## Wire the firmware/Dart protocol contract test into CI - Minimal

`firmware/test/test_pedal_protocol.c` is the only proof that the AVR
firmware's `pedal_protocol.c` and Dart's `PedalCodec`
(`packages/pedal_repository`) agree byte-for-byte on the SysEx wire format. Its
header comment claims "No board required — runs in CI exactly like the
engine's native MIDI suite," but no CI job anywhere builds or runs it
(`grep -rn "firmware" .github/workflows/` returns nothing). A future change
that breaks firmware/Dart parity would merge silently. Fix: add a step to the
existing `native-tests` job in `.github/workflows/main.yaml` that builds and
runs this test with the exact command already documented in
`firmware/README.md`'s "Contract test (host, no board)" section.

## Success Criteria

```success-criteria
GOAL: firmware/test/test_pedal_protocol.c is built and run on every CI push/PR via the existing native-tests job, so a firmware/Dart wire-format regression fails CI instead of merging silently.

SUCCESS CRITERIA:
- .github/workflows/main.yaml's native-tests job has a step that compiles and runs firmware/test/test_pedal_protocol.c against firmware/loopy_pedal/pedal_protocol.c using the command documented in firmware/README.md | verify: grep -n "test_pedal_protocol.c" .github/workflows/main.yaml
- The exact command from firmware/README.md's "Contract test (host, no board)" section builds and passes locally from the repo root, printing "ALL PASSED" | verify: gcc -std=c11 -Wall -I firmware/loopy_pedal firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests && /tmp/pedal_protocol_tests | grep -q "ALL PASSED"
- The new CI step is inside the native-tests job (not a new job) and comes after the existing native engine/MIDI step | verify: manual 1. Open .github/workflows/main.yaml 2. Confirm the new step's YAML key is nested under `native-tests: steps:` 3. Confirm it appears after the "Build + run native engine/MIDI tests" step
- main.yaml is valid YAML | verify: python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/main.yaml'))"
- No other CI job, script, or unrelated file is modified | verify: git diff --stat master... | grep -v -E "main.yaml|test_pedal_protocol.c|docs/(brainstorm|plan)/" ; test $? -eq 1

NON-GOALS:
- Folding the firmware test into packages/loopy_engine/src/test/run_native_tests.sh (rejected in brainstorm — different working-directory convention, no benefit).
- Adding a new standalone CI job for this test.
- Changing pedal_protocol.c/.h, PedalCodec, or any golden .syx fixtures.
- Fixing any other finding from the same review pass.

VERIFICATION COMMAND: gcc -std=c11 -Wall -I firmware/loopy_pedal firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests && /tmp/pedal_protocol_tests | grep -q "ALL PASSED" && grep -n "test_pedal_protocol.c" .github/workflows/main.yaml && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/main.yaml'))"
```

## Context

- `firmware/README.md` lines 116-132 ("Contract test (host, no board)") documents the canonical build/run command:
  ```sh
  gcc -std=c11 -Wall -I firmware/loopy_pedal \
    firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c \
    -o pedal_protocol_tests && ./pedal_protocol_tests
  # expected last line: ALL PASSED
  ```
  Must run from the repo root — the test's default fixtures path
  (`packages/pedal_repository/test/fixtures`, set at
  `firmware/test/test_pedal_protocol.c:38`) is relative to cwd.
- `.github/workflows/main.yaml`'s `native-tests` job (~line 104-113) already
  runs on `ubuntu-latest`, installs `build-essential libasound2-dev`, and runs
  `packages/loopy_engine/src/test/run_native_tests.sh`. GitHub Actions
  `run:` steps default to the repo-root working directory, so the documented
  command works unmodified as a new step here — no extra `working-directory:`
  needed.
- `packages/loopy_engine/src/test/run_native_tests.sh` is NOT touched: it
  opens with `cd "$(dirname "$0")/../.."`, landing in `packages/loopy_engine`,
  a different cwd than the firmware test needs. Keeping the firmware step as
  its own `run:` step (rather than folding it into that script) avoids
  fighting that convention (per brainstorm doc, rejected alternative).
- The job's existing block comment (lines 99-103 of main.yaml) says
  "`run_native_tests.sh` builds and runs both suites" — needs a one-line
  update since a third, separately-invoked suite is being added to the same
  job.
- `firmware/test/test_pedal_protocol.c` lines 1-21 (file header): currently
  states "No board required — runs in CI exactly like the engine's native MIDI
  suite." Once this step lands, that statement becomes literally true —
  leave the substance as-is per brainstorm's decision; only touch wording if
  it reads oddly once the actual step exists (e.g., if the step name/phrasing
  in main.yaml doesn't match "exactly like").
- Brainstorm doc: `docs/brainstorm/2026-07-13-firmware-contract-test-ci-brainstorm-doc.md`

## MVP

`.github/workflows/main.yaml`, inside the `native-tests` job, directly after
the existing `- name: Build + run native engine/MIDI tests` step:

```yaml
      - name: Build + run firmware/Dart protocol contract test
        run: |
          gcc -std=c11 -Wall -I firmware/loopy_pedal \
            firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c \
            -o pedal_protocol_tests
          ./pedal_protocol_tests
```

Update the job's leading comment block to mention this third step so it
doesn't go stale, e.g. append a sentence noting the firmware contract test now
also runs here, alongside the two run_native_tests.sh suites.

No changes to `run_native_tests.sh`, `pedal_protocol.c/.h`, `PedalCodec`, or
any fixtures.

## References

- `firmware/README.md` — "Contract test (host, no board)" section (canonical command)
- `firmware/test/test_pedal_protocol.c` — header comment + default fixtures path
- `.github/workflows/main.yaml` — `native-tests` job
- `packages/loopy_engine/src/test/run_native_tests.sh` — sibling native-suite runner (not modified, kept as reference for job comment wording)
- Brainstorm: `docs/brainstorm/2026-07-13-firmware-contract-test-ci-brainstorm-doc.md`
