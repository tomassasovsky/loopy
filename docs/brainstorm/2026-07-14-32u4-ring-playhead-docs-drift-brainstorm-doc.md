---
date: 2026-07-14
topic: 32u4-ring-playhead-docs-drift
---

# 32U4 pedal ring: "loop-position playhead" docs drift (sibling of #176)

## What We're Building

A docs-and-comment-only fix, mirroring PR #176 (commit `668cb2d`), applied to
`hardware/firmware/loopy_pedal_32u4/` — the newer THT/Pro-Micro firmware port
added by the "feat(pedal): 32U4 firmware + THT main-board bring-up" commit,
which #176 did not touch because it didn't exist on `master` at diff time.

`renderRing()` in `loopy_pedal_32u4.ino` is confirmed byte-for-byte the same
fixed-cadence algorithm as the old UNO firmware: `kRingMsPerRev = 700`,
`g_ringPhase` advances by `dt / kRingMsPerRev * kRingCount` every frame, with
no reference to `g_frame.loop_length_micros` anywhere in that math.
(`loop_length_micros` is read exactly once, in `renderRing()`, only to decide
whether a Stop should freeze the ring — not to size the sweep.) Despite this,
several comments and the README describe the ring as tracking "loop-position"
or acting as a "playhead" — implying it visually represents where a loop
currently is, which it does not.

A full grep of the directory for `loop-position|playhead|revolution` found
more instances than the originating issue listed:

- `loopy_pedal_32u4.ino:16` — "RING (D15): the off-the-shelf 16-LED NeoPixel
  ring, loop-position."
- `loopy_pedal_32u4.ino:39` — "RING strip: the 16-LED NeoPixel ring on D15
  (loop-position playhead)."
- `loopy_pedal_32u4.ino:321` — "Map the logical playhead to the mirrored
  physical LED so the hump rotates CLOCKWISE..."
- `loopy_pedal_32u4.ino:329` — "Fills clockwise (the same sense as the
  loop-position hump)..."
- `loopy_pedal_32u4.ino:354` — "...the frozen-playhead ring holds steady..."
- `loopy_pedal_32u4.ino:431` — "// shows the loop-position playhead. Signed
  compare is millis()-wrap safe."
- `README.md:67` — "...the frozen-playhead ring holds steady instead of
  decaying."
- `README.md:168` — "...its state frames drive the two strips (ring
  playhead, track colors...)"

Also present: `g_lastLoopTopMs` (line 97, written at line 203 in
`consumeByte()`) is captured but never read to drive the ring — the same
dead-write pattern #176 found and annotated in the old firmware.

`packages/pedal_repository/lib/src/pedal_codec.dart`'s `loopTopPulse` doc
comment is **shared** between both firmware ports and was already corrected
by #176 — it needs no further change here.

The fix: reword every "loop-position"/"playhead" instance in
`loopy_pedal_32u4.ino` and its `README.md` to describe the actual
fixed-cadence decorative sweep, and add a clarifying comment at
`g_lastLoopTopMs`'s declaration marking it reserved-for-possible-future-use,
matching #176's treatment of the old firmware exactly.

## Why This Approach

**Scope question:** lines 321, 329, and 354 use "playhead"/"loop-position"
more loosely — naming the currently-lit LED or describing rotation
direction/sense, not directly asserting loop-length sync. Two options were
considered for how far the fix should reach:

**A — Fix only the clear claims (lines 16, 39, 431, README 67/168).** Matches
#176's precedent most literally: touch only the sentences that assert the
false capability, leave rotation-mechanics comments alone.

- Pros: smallest possible diff; exactly mirrors what #176 did for the old
  firmware (which had no equivalent of lines 321/329/354 to begin with, since
  its single-strip layout doesn't have a separate volume-bar mode reusing the
  ring).
- Cons: leaves "playhead" and "loop-position" as the vocabulary used to name
  the rotating hump throughout the rest of the file, which keeps the door
  open to the same misreading recurring (e.g., a future contributor grep'ing
  for "playhead" would still find it used un-ironically to describe the ring
  in 3 more places).

**B — Fix every instance for internal consistency (chosen, user-selected).**
Reword all 8 occurrences (6 in the `.ino`, 2 in the `README.md`) to avoid the
loop-sync implication entirely, using neutral terms like "the rotating hump"
/ "the lit LED" / "frozen ring" instead of "playhead".

- Pros: the file no longer uses "playhead" anywhere to describe the ring,
  removing any residual ambiguity; keeps the fix self-consistent rather than
  leaving 3 of 8 instances of the same word with a different (correct)
  meaning nearby. Still a comment-only diff — no behavior risk.
- Cons: slightly larger diff than the minimal literal-precedent match; lines
  321/329/354 were arguably not "wrong" (they don't claim loop-sync, just use
  a loaded word) so this is a stricter-than-necessary bar.
- Best when: consistency and foreclosing future misreadings is valued over
  strict diff-size minimalism — true here, since it's still docs/comments
  only with zero runtime risk.

**Decision: Option B.** Selected by the user when asked to weigh the two
scopes. Since this is a zero-risk comment/docs change (no firmware behavior
touched, nothing to validate on hardware), the larger but still-trivial diff
of Option B is worth the consistency gain.

## Key Decisions

- **Decision: docs/comments only, no firmware behavior change.** Same
  rationale as #176: this is filed as correctness/docs-drift, not a
  user-facing "the ring looks wrong" bug report; the fixed-cadence sweep
  reads as a deliberate, tuned design choice (explicit "Independent of loop
  length" comment already sits above `kRingMsPerRev`); there is no hardware
  in this sandboxed worktree to validate a behavior change against; and the
  algorithm is byte-for-byte identical to the old firmware, which already
  went through this exact analysis in #176.
- **Decision: reword all 8 "playhead"/"loop-position" instances (option B),**
  not just the 5 the originating issue explicitly named. Rationale: the
  extra 3 spots use the same misleading word even though they don't strictly
  assert loop-sync; fixing them keeps the file's vocabulary consistent about
  what the ring actually is, at zero additional risk since this is a
  comment-only change.
- **Decision: keep `g_lastLoopTopMs` and its write site, add a clarifying
  comment instead of deleting.** Mirrors #176 exactly: the firmware must keep
  consuming the `PEDAL_LOOP_TOP` (`0xFA`) real-time byte off the wire
  regardless (`consumeByte()` needs the branch so the byte doesn't corrupt
  in-progress SysEx assembly); the timestamp capture is harmless and cheap;
  keeping it — clearly labeled unused/reserved — preserves a hook for a
  possible future loop-synced rendering mode without pretending the
  capability exists today.
- **Decision: do not touch `packages/pedal_repository/lib/src/pedal_codec.dart`.**
  It's shared between both firmware ports and was already corrected by #176;
  re-editing it here would be either a no-op or scope creep into an unrelated
  file.
- **Decision: no test changes.** No test harness exists for
  `renderRing()`/`consumeByte()`'s ring-timestamp branch (Arduino
  `millis()`/FastLED can't run on host); this fix is comments/docs only, so
  no new tests are warranted. The existing host-compiled
  `pedal_protocol.c`/`.h` mirror test and Dart `pedal_codec_test.dart` are
  unaffected since neither file changes.

## Open Questions

- None blocking. If a future contributor wants to implement real loop-synced
  ring rotation, the same caveats #176 raised apply here too (needs real
  hardware to tune min/max revolution-time clamps and verify interaction with
  the freeze-on-stop / clear-to-dark logic) — not resolved by this docs fix.
