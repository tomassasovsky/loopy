---
date: 2026-07-13
topic: loop-top-sync-docs-drift
---

# Loop-top sync pulse: dead capture + docs drift

## What We're Building

A docs-and-comment fix (option B from the issue) rather than a firmware
behavior change (option A). `firmware/loopy_pedal/loopy_pedal.ino` captures
the loop-top sync pulse (`onLoopTop()` writes `g_lastLoopTopMs = millis()`)
but never reads it — the ring animation in `renderRing()` is driven entirely
by a free-running fixed-cadence timer (`kRingMsPerRev = 700`), independent of
loop length, as the code's own comment already states. Two docs describe the
undelivered behavior ("one revolution per loop"): the `loopTopPulse` doc
comment in `packages/pedal_repository/lib/src/pedal_codec.dart` and
`firmware/README.md`'s LED-map table.

The fix: correct both docs to describe the actual fixed-cadence decorative
sweep, and add a short comment at `g_lastLoopTopMs`'s declaration and in
`onLoopTop()` explaining it is presently captured but unused — reserved for a
possible future loop-synced rendering mode — rather than leaving it looking
like an oversight.

## Why This Approach

Considered two approaches:

**A — Implement documented loop-synced rotation (not recommended for this
fix).** Drive `g_ringPhase` from `g_lastLoopTopMs` and
`g_frame.loop_length_micros` instead of (or blended with) the fixed timer,
capping the effective revolution time to a sane min/max (e.g. clamp effective
period to something like 300 ms–4 s) so very short loops don't strobe and
very long loops (a 30-minute loop) don't look frozen.

- Pros: makes the ring do what the docs (and presumably the original design
  intent) describe; more informative visual feedback tied to the actual loop.
- Cons: this is a real behavior change to code that drives physical LEDs on
  hardware neither this worktree nor CI has access to (no board, no way to
  visually verify the new sweep feels right). It interacts with the existing
  freeze-on-stop / clear-to-dark logic in `renderRing()`, which is carefully
  tuned (see the long comment above `kRingMsPerRev`) and not obviously
  compatible with a loop-length-driven phase without further design work
  (e.g., what happens when `loop_length_micros` is 0 / no loop recorded yet,
  or changes mid-loop on overdub). There is no test harness for `renderRing()`
  — `firmware/test/test_pedal_protocol.c` only exercises the host-compiled
  `pedal_protocol.c` SysEx codec, not the Arduino sketch's FastLED/`millis()`
  rendering — so this change would ship unverified beyond a compile check.
  This mirrors the project's own precedent of pausing hardware-dependent
  firmware work pending real hardware access (see the VST3 plugin parts
  12-17 pause for missing signing certs / other-OS hardware).
- Best when: someone has the physical pedal in hand to tune and verify the
  new sweep, and wants the ring to be functionally loop-synced as a real
  product decision — a bigger change than "fix this one drifted doc."

**B — Correct the docs, explain the dead write (recommended).** Update the
`loopTopPulse` doc comment and the README LED-map row to describe the actual
current behavior (fixed ~700 ms decorative sweep, independent of loop
length), and add a one-line comment clarifying `g_lastLoopTopMs` /
`onLoopTop()` are currently unused / reserved for possible future
loop-synced rendering.

- Pros: low risk, no behavior change to code driving real hardware, resolves
  the actual filed issue (docs contradict code) without needing hardware to
  verify. Keeps the wire-protocol byte and its capture in place (harmless,
  and consuming/discarding the `0xFA` byte in `pollMidiIn()` is required
  regardless, since real-time bytes must not fall into the SysEx buffer).
- Cons: doesn't make the ring "more correct" visually; leaves the fixed-timer
  sweep as-is (which was already presumably an intentional, tuned design
  choice, not a bug — the "Independent of loop length" comment reads as
  deliberate).
- Best when: severity is low, the issue is filed as correctness/docs-drift
  (not "the ring looks bad"), and there's no hardware in this sandboxed
  worktree to validate a firmware behavior change against.

**Decision: Option B.** This issue is filed as `low` severity,
`correctness / docs-drift`, not a user-facing bug report that the ring looks
wrong. The issue's own suggested-fix-direction explicitly leans toward B
unless a "clear, low-risk way to do (A) well" turns up — and it hasn't: (A)
requires picking and hand-tuning min/max clamp values with no hardware to
verify against, and touches carefully-tuned freeze/clear-to-dark logic with
zero test coverage for that code path. Per this task's scope constraints
(fix exactly one issue, narrowly, don't refactor unrelated code, no live
user to approve a riskier hardware-facing change), B is the correct call.

## Key Decisions

- **Decision: fix docs, not firmware behavior.** Update
  `packages/pedal_repository/lib/src/pedal_codec.dart`'s `loopTopPulse` doc
  comment and `firmware/README.md`'s LED-map table to describe the actual
  fixed-cadence sweep instead of the aspirational "one revolution per loop."
  Rationale: low severity, no hardware to validate a firmware behavior
  change, existing sweep logic is deliberately tuned.
- **Decision: keep `g_lastLoopTopMs` / `onLoopTop()`, add a clarifying
  comment instead of deleting them.** Rationale: the firmware must keep
  consuming the `0xFA` real-time byte off the wire regardless (so it doesn't
  corrupt in-progress SysEx assembly in `pollMidiIn()`); recording the
  timestamp is harmless and cheap, and keeping it — clearly labeled as
  currently-unused/reserved — preserves a hook for a future loop-synced
  rendering mode (option A) without pretending the capability exists today.
  Deleting it would require touching `pollMidiIn()`'s dispatch to still
  swallow the byte, which is a larger and less obviously beneficial diff for
  a low-severity docs fix.
- **Decision: no test changes.** There is no test harness for
  `renderRing()`/`onLoopTop()` (only `pedal_protocol.c`'s wire codec has host
  tests); this fix is comments/docs only, so no new tests are warranted.

## Open Questions

- None blocking. If a future contributor wants to pursue option A, the
  min/max revolution-time clamp values and the interaction with
  freeze-on-stop/clear-to-dark would need real hardware to tune — flagged in
  this doc for that future work, not resolved here.
