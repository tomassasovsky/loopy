---
title: Fix loop-top sync pulse docs drift
type: fix
date: 2026-07-13
---

## Fix loop-top sync pulse docs drift - Minimal

`firmware/loopy_pedal/loopy_pedal.ino` captures the loop-top sync pulse
(`onLoopTop()` sets `g_lastLoopTopMs = millis()`) but never reads it —
`renderRing()`'s ring animation is driven entirely by a free-running
fixed-cadence timer (`kRingMsPerRev = 700`), independent of loop length, as
the code's own comment already states. Two docs claim the undelivered
behavior ("one revolution per loop"):
`packages/pedal_repository/lib/src/pedal_codec.dart`'s `loopTopPulse` doc
comment, and `firmware/README.md`'s LED-map table.

Per `docs/brainstorm/2026-07-13-loop-top-sync-docs-drift-brainstorm-doc.md`,
this fix corrects the docs to describe actual behavior (option B) rather
than implementing loop-synced rotation (option A), since severity is low,
there's no hardware in this sandboxed worktree to validate a firmware
behavior change, and the existing fixed-cadence sweep reads as a deliberate,
already-tuned design choice. It also adds a short comment at
`g_lastLoopTopMs`'s declaration explaining it is currently captured but
unused (reserved for potential future loop-synced rendering), instead of
leaving it looking like an oversight. `onLoopTop()` itself is left
unchanged — one comment at the declaration is the single source of truth,
so it is not duplicated at the write site.

## Success Criteria

```success-criteria
GOAL: The docs and firmware comments accurately describe the pedal ring's actual fixed-cadence behavior, and the dead g_lastLoopTopMs capture is clearly explained as intentionally-unused rather than looking like an oversight — with no change to actual rendering/runtime behavior.

SUCCESS CRITERIA:
- packages/pedal_repository/lib/src/pedal_codec.dart's loopTopPulse doc comment no longer claims the firmware "advances its ring one revolution per loop"; it accurately describes the current fixed-cadence decorative sweep and notes the pulse is reserved for possible future loop-synced rendering | verify: grep -q "revolution per loop" packages/pedal_repository/lib/src/pedal_codec.dart && exit 1 || exit 0
- firmware/README.md's LED-map row for the ring (index 0-11) no longer claims "one revolution per loop"; it describes the actual fixed-cadence decorative sweep | verify: grep -q "one revolution per loop" firmware/README.md && exit 1 || exit 0
- firmware/loopy_pedal/loopy_pedal.ino has a comment immediately before g_lastLoopTopMs's declaration clarifying it is currently unused/reserved | verify: grep -B3 "static unsigned long g_lastLoopTopMs = 0;" firmware/loopy_pedal/loopy_pedal.ino | grep -qi "unused\|reserved\|not.*read\|not.*yet"
- No functional/behavioral code changes: renderRing(), kRingMsPerRev, g_ringPhase advance logic, and pollMidiIn()'s dispatch are byte-for-byte unchanged | verify: git diff --unified=0 -- firmware/loopy_pedal/loopy_pedal.ino | grep -E '^[+-]' | grep -v '^[+-][+-][+-]' | grep -vE '^\+//|^\-//|^\+\s*$' | grep -qE 'renderRing|kRingMsPerRev|g_ringPhase|pollMidiIn' && exit 1 || exit 0
- The pedal firmware sketch still compiles cleanly after the comment edits | verify: arduino-cli core list | grep -q arduino:avr || arduino-cli core install arduino:avr; arduino-cli compile --fqbn arduino:avr:uno firmware/loopy_pedal
- Existing pedal protocol host test suite still passes unchanged (this fix does not touch pedal_protocol.c/.h) | verify: gcc -std=c11 -I firmware/loopy_pedal firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests && /tmp/pedal_protocol_tests
- Existing Dart tests for pedal_codec.dart still pass unchanged (doc-comment-only edit) | verify: cd packages/pedal_repository && /Users/Tomas/development/flutter/bin/flutter test test/pedal_codec_test.dart

NON-GOALS:
- Implementing actual loop-synced ring rotation (option A) — explicitly deferred per the brainstorm doc's risk assessment (no hardware to validate, interacts with tuned freeze/clear-to-dark logic).
- Any change to firmware/led_driver, hardware/kicad, or any other issue from the same review pass.
- Removing g_lastLoopTopMs/onLoopTop() outright — kept and documented instead (see brainstorm doc rationale).

VERIFICATION COMMAND: (arduino-cli core list | grep -q arduino:avr || arduino-cli core install arduino:avr) && arduino-cli compile --fqbn arduino:avr:uno firmware/loopy_pedal && gcc -std=c11 -I firmware/loopy_pedal firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests && /tmp/pedal_protocol_tests && (cd packages/pedal_repository && /Users/Tomas/development/flutter/bin/flutter test test/pedal_codec_test.dart)
```

## Context

- `firmware/loopy_pedal/loopy_pedal.ino`:
  - Line ~73-74: `g_lastLoopTopMs` declaration, comment currently reads
    "Loop-position interpolation: time of the last loop-top pulse + loop
    length." (this comment itself is aspirational/inaccurate — no
    interpolation is actually implemented — and should be corrected too).
  - Line ~118-120: `onLoopTop()` — the only write site.
  - Line ~188-198: the `renderRing()` doc comment above `kRingMsPerRev`
    already correctly states the sweep is "Independent of loop length" —
    leave this as-is, it's accurate.
  - Line ~202-237: `renderRing()` body — do not touch.
- `packages/pedal_repository/lib/src/pedal_codec.dart` lines 58-63: the
  `loopTopPulse` constant's doc comment claims "the firmware advances its
  ring one revolution per loop" — this is the drifted claim to fix.
- `firmware/README.md` line 90: LED-map table row `| 0–11 | the 12-LED
  loop-position ring (one revolution per loop) |` — same drifted claim.
- No existing test harness covers `renderRing()`/`onLoopTop()` (Arduino
  `millis()`/FastLED can't run on host); only `pedal_protocol.c`'s wire codec
  has a host test (`firmware/test/test_pedal_protocol.c`). This fix is
  docs/comments only, so no new tests are added — verification is via the
  existing compile + existing test suites staying green, plus grep checks
  confirming the drifted text is gone and the new clarifying comment exists.
- Dart side: the existing test file is
  `packages/pedal_repository/test/pedal_codec_test.dart` (no `test/src/`
  subdirectory — confirmed via `find`). It imports `package:flutter_test`,
  not `package:test`, so it must run via `flutter test`, not `dart test`.
  Per the Loopy test-runner gotcha from memory, the `very_good` MCP test
  tool is broken for this repo and bare `flutter test` can hit a repo hook —
  use the absolute binary path `/Users/Tomas/development/flutter/bin/flutter
  test test/pedal_codec_test.dart` (run from `packages/pedal_repository`),
  confirmed to resolve on this machine (no fvm install present).

## MVP

1. `packages/pedal_repository/lib/src/pedal_codec.dart` — rewrite the
   `loopTopPulse` doc comment (lines ~58-63):

   ```dart
   /// The MIDI System Real-Time "Start" status byte (`0xFA`), reused as the
   /// loop-top pulse: loopy sends one byte at each loop top. The firmware
   /// currently only records the pulse's arrival time (`g_lastLoopTopMs`) and
   /// does not use it to drive the ring — v1's ring is a fixed-cadence
   /// decorative sweep independent of loop length (see `renderRing()` in
   /// loopy_pedal.ino). The pulse is reserved for a possible future
   /// loop-synced rendering mode. A single real-time byte survives the
   /// firmware's FastLED interrupt gap far better than multi-byte SysEx.
   static const loopTopPulse = 0xFA;
   ```

2. `firmware/README.md` — rewrite the LED-map ring row (line ~90):

   ```markdown
   | 0–11 | the 12-LED loop-position ring (fixed-cadence decorative sweep, ~700 ms/revolution; not currently synced to loop length) |
   ```

3. `firmware/loopy_pedal/loopy_pedal.ino`:
   - Correct the `g_lastLoopTopMs` declaration comment (~line 73) from the
     inaccurate "Loop-position interpolation: ..." to something like:

     ```cpp
     // Timestamp of the last loop-top pulse (0xFA) from loopy. Currently
     // unused: v1's ring (see renderRing()) is a fixed-cadence sweep
     // independent of loop length. Reserved for a possible future
     // loop-synced rendering mode.
     static unsigned long g_lastLoopTopMs = 0;
     ```

   - The declaration comment above is the single source of truth for this
     explanation — do not duplicate it at `onLoopTop()`'s definition
     (~line 118, a one-line function; a second comment repeating the same
     explanation there would be redundant per the simplicity review of this
     plan). Leave `onLoopTop()` itself unchanged.

4. Run the verification command block above (arduino-cli compile + host
   protocol test suite + Dart test) to confirm nothing else changed
   behaviorally.

No other files change. No test files are added (nothing new to test — this
is a documentation/comment correction).

## References

- Issue source: multi-agent code review finding, re-verified at commit
  `f3f5b76` (origin/master HEAD).
- Brainstorm doc:
  `docs/brainstorm/2026-07-13-loop-top-sync-docs-drift-brainstorm-doc.md`
- Related code: `firmware/loopy_pedal/loopy_pedal.ino`,
  `packages/pedal_repository/lib/src/pedal_codec.dart`,
  `firmware/README.md`
