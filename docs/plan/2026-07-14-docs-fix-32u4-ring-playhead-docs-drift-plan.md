---
title: Fix 32U4 pedal ring "playhead" docs drift
type: fix
date: 2026-07-14
---

## Fix 32U4 pedal ring "playhead" docs drift - Minimal

`hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino`'s `renderRing()` is
confirmed byte-for-byte the same fixed-cadence algorithm as
`firmware/loopy_pedal/loopy_pedal.ino` (the older UNO port already fixed in
PR #176 / commit `668cb2d`): `kRingMsPerRev = 700`, `g_ringPhase` advances by
`dt / kRingMsPerRev * kRingCount` every frame, with no reference anywhere to
`g_frame.loop_length_micros` in that math. Despite this, the `.ino` and its
`README.md` describe the ring as a "loop-position playhead" in 8 places
(6 in the `.ino`, 2 in the README) — implying it visually tracks where a loop
currently is, which it does not. `g_lastLoopTopMs` (declared at line 97,
written in `consumeByte()` at line 203) is captured but never read to drive
the ring — the same dead-write pattern PR #176 found and annotated in the old
firmware.

Per `docs/brainstorm/2026-07-14-32u4-ring-playhead-docs-drift-brainstorm-doc.md`,
this fix corrects all 8 "playhead"/"loop-position" instances (not just the 5
that clearly assert loop-sync) for internal consistency, and adds a comment
at `g_lastLoopTopMs`'s declaration marking it reserved-for-possible-future-use
— mirroring PR #176's treatment of the old firmware. No firmware behavior
changes; `packages/pedal_repository/lib/src/pedal_codec.dart` is untouched
(shared file, already corrected by #176).

## Success Criteria

```success-criteria
GOAL: hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino and its README.md accurately describe the ring's actual fixed-cadence sweep instead of implying loop-position/playhead tracking, with zero change to rendering/runtime behavior.

SUCCESS CRITERIA:
- No "loop-position" or "playhead" text remains describing the ring anywhere in loopy_pedal_32u4.ino or its README.md | verify: ! grep -ni "loop-position\|playhead" hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino hardware/firmware/loopy_pedal_32u4/README.md
- loopy_pedal_32u4.ino has a comment at g_lastLoopTopMs's declaration clarifying it is currently unused/reserved | verify: grep -B2 "static unsigned long g_lastLoopTopMs = 0;" hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino | grep -qi "unused\|reserved\|not.*read\|not.*yet"
- No functional/behavioral code changes: renderRing(), kRingMsPerRev, g_ringPhase advance math, consumeByte()'s dispatch, and renderVolumeBar()'s math are byte-for-byte unchanged (only comments/strings differ) | verify: git diff --unified=0 -- hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino | grep -E '^[+-]' | grep -v '^[+-][+-][+-]' | grep -vE '^\+//|^\-//|^\+\s*$' | grep -qE 'kRingMsPerRev|kRingWidth|kRingShape|g_ringPhase \+=|g_frame\.master_gain|PEDAL_LOOP_TOP' && exit 1 || exit 0
- The pedal firmware sketch still compiles cleanly after the comment/doc edits | verify: (arduino-cli core list | grep -q avr:avr || arduino-cli core install arduino:avr) && arduino-cli compile --fqbn arduino:avr:leonardo hardware/firmware/loopy_pedal_32u4
- Existing pedal protocol host test suite still passes unchanged (this fix does not touch pedal_protocol.c/.h, which must stay byte-identical to the old firmware's copy) | verify: diff hardware/firmware/loopy_pedal_32u4/pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c && diff hardware/firmware/loopy_pedal_32u4/pedal_protocol.h firmware/loopy_pedal/pedal_protocol.h && gcc -std=c11 -I firmware/loopy_pedal firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests_32u4 && /tmp/pedal_protocol_tests_32u4
- Existing Dart tests for pedal_codec.dart still pass unchanged (that file is not touched by this fix) | verify: cd packages/pedal_repository && /Users/Tomas/development/flutter/bin/flutter test test/pedal_codec_test.dart

NON-GOALS:
- Implementing actual loop-synced ring rotation — explicitly out of scope, same rationale as PR #176 (no hardware in this sandboxed worktree to validate a firmware behavior change, existing fixed-cadence sweep reads as a deliberate, already-tuned design choice).
- Touching packages/pedal_repository/lib/src/pedal_codec.dart — already corrected by PR #176, shared between both firmware ports.
- Any change to firmware/loopy_pedal/ (the old firmware) — already fixed by PR #176.
- Removing g_lastLoopTopMs / its write site outright — kept and documented instead, matching PR #176's rationale (the real-time byte must still be consumed off the wire regardless).

VERIFICATION COMMAND: ! grep -ni "loop-position\|playhead" hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino hardware/firmware/loopy_pedal_32u4/README.md && grep -B2 "static unsigned long g_lastLoopTopMs = 0;" hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino | grep -qi "unused\|reserved\|not.*read\|not.*yet" && (arduino-cli core list | grep -q avr:avr || arduino-cli core install arduino:avr) && arduino-cli compile --fqbn arduino:avr:leonardo hardware/firmware/loopy_pedal_32u4 && diff hardware/firmware/loopy_pedal_32u4/pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c && diff hardware/firmware/loopy_pedal_32u4/pedal_protocol.h firmware/loopy_pedal/pedal_protocol.h && gcc -std=c11 -I firmware/loopy_pedal firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests_32u4 && /tmp/pedal_protocol_tests_32u4 && (cd packages/pedal_repository && /Users/Tomas/development/flutter/bin/flutter test test/pedal_codec_test.dart)
```

## Context

- `hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino` — the 8 sites to
  reword (all comments/doc strings, no code):
  - Line 16: `//       - RING (D15): the off-the-shelf 16-LED NeoPixel ring, loop-position.`
  - Line 39: `// RING strip: the 16-LED NeoPixel ring on D15 (loop-position playhead).`
  - Line 97: `static unsigned long g_lastLoopTopMs = 0; // time of the last loop-top pulse` — add a "currently unused/reserved" clarifying comment above the declaration (matching PR #176's treatment), not just reword the inline comment.
  - Line 321 (in `renderRing()`): `// Map the logical playhead to the mirrored physical LED so the hump rotates`
  - Line 329 (in `renderVolumeBar()`'s doc comment): `// same sense as the loop-position hump); the top LED dims for the fractional part.`
  - Line 354 (gamma-correction doc comment): `// SEPARATE display buffers — not in place — matters: the frozen-playhead ring`
  - Line 431 (near the link-timeout / render dispatch): `// shows the loop-position playhead. Signed compare is millis()-wrap safe.`
- `hardware/firmware/loopy_pedal_32u4/README.md` — the 2 sites to reword:
  - Line 67: `at output into a separate display buffer, so the frozen-playhead ring holds steady`
  - Line 168: `3. With the loopy app bound, its state frames drive the two strips (ring playhead,`
- Do NOT touch `firmware/README.md`, `firmware/loopy_pedal/loopy_pedal.ino`, or
  `packages/pedal_repository/lib/src/pedal_codec.dart` — all three already
  fixed by PR #176 (commit `668cb2d`), and `pedal_codec.dart` is shared
  between both firmware ports.
- `pedal_protocol.c`/`.h` in `hardware/firmware/loopy_pedal_32u4/` are
  byte-for-byte mirrors of `firmware/loopy_pedal/`'s copies (per this file's
  own header comment, lines 24-26) — this fix does not touch either, so the
  mirror-diff and host test suite are just a regression guard here, not a new
  requirement.
- No test harness exists for `renderRing()`/`consumeByte()`'s ring-timestamp
  branch (Arduino `millis()`/FastLED can't run on host) — same limitation
  PR #176 documented for the old firmware. This fix is comments/docs only,
  so no new tests are added.
- Per the Loopy test-runner gotcha from memory: the `very_good` MCP test tool
  is broken for this repo; use the absolute Flutter binary path
  `/Users/Tomas/development/flutter/bin/flutter test test/pedal_codec_test.dart`
  (run from `packages/pedal_repository`) rather than bare `flutter test`.
- Board fqbn for this port is `arduino:avr:leonardo` (Pro Micro / ATmega32U4
  shares the Leonardo core), per this folder's own README compile
  instructions — NOT `arduino:avr:uno` (that's the old firmware's board).

## MVP

1. `hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino` — reword all 6
   sites listed above to describe the actual fixed-cadence decorative sweep
   or neutral rotation mechanics, e.g.:
   - Line 16 → `//       - RING (D15): the off-the-shelf 16-LED NeoPixel ring, a fixed-cadence decorative sweep.`
   - Line 39 → `// RING strip: the 16-LED NeoPixel ring on D15 (fixed-cadence decorative sweep; see renderRing()).`
   - Line 97 → add above the declaration:
     ```cpp
     // Timestamp of the last loop-top pulse (PEDAL_LOOP_TOP). Currently
     // unused: the ring (see renderRing()) is a fixed-cadence sweep
     // independent of loop length. Reserved for a possible future
     // loop-synced rendering mode.
     static unsigned long g_lastLoopTopMs = 0;
     ```
   - Line 321 → `// Map the rotating hump's logical index to the mirrored physical LED so it rotates`
   - Line 329 → `// same sense as the ring's rotating hump); the top LED dims for the fractional part.`
   - Line 354 → `// SEPARATE display buffers — not in place — matters: the frozen ring`
   - Line 431 → `// shows the ring's fixed-cadence decorative sweep. Signed compare is millis()-wrap safe.`
2. `hardware/firmware/loopy_pedal_32u4/README.md` — reword the 2 sites:
   - Line 67 → `at output into a separate display buffer, so the frozen ring holds steady`
   - Line 168 → `3. With the loopy app bound, its state frames drive the two strips (ring sweep,`
3. Run the verification command block above to confirm the drifted text is
   gone, the new clarifying comment exists, no functional code changed, the
   sketch still compiles, and both existing test suites (host C protocol
   test, Dart `pedal_codec_test.dart`) still pass.

No other files change. No test files are added — this is a
documentation/comment correction with no new behavior to test.

## References

- Precedent: PR #176 / commit `668cb2d` — `docs(pedal): correct loop-top
  ring-sync docs to match actual firmware`, which fixed the identical bug in
  `firmware/loopy_pedal/loopy_pedal.ino`, `firmware/README.md`, and
  `packages/pedal_repository/lib/src/pedal_codec.dart`.
- Brainstorm doc:
  `docs/brainstorm/2026-07-14-32u4-ring-playhead-docs-drift-brainstorm-doc.md`
- Related code: `hardware/firmware/loopy_pedal_32u4/loopy_pedal_32u4.ino`,
  `hardware/firmware/loopy_pedal_32u4/README.md`
