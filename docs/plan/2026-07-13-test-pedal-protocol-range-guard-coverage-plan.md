---
title: test: cover pedal_decode_frame's out-of-range field rejection
type: test
date: 2026-07-13
---

## test: cover pedal_decode_frame's out-of-range field rejection - Minimal

`firmware/loopy_pedal/pedal_protocol.c`'s `pedal_decode_frame()` (~line 107-117)
has four defensive range-check guards that reject an otherwise
checksum-valid, correctly-framed message: an out-of-range `global_color`
(`>= PEDAL_GLOBAL_COUNT`), `active_bank` (`> 1`), `armed_track`
(`>= PEDAL_TRACK_COUNT`), and any `track_leds[i]` (`>= PEDAL_LED_COUNT`). None
of these four branches is exercised by
`firmware/test/test_pedal_protocol.c` today —
`test_malformed_frames_are_rejected()` only covers checksum corruption, wrong
protocol version, wrong manufacturer id, and truncation. This plan adds one
`CHECK` per guard to that same test function, closing the gap. No production
code changes; no CI config changes (a separate, parallel effort wires this
suite into CI).

## Success Criteria

```success-criteria
GOAL: firmware/test/test_pedal_protocol.c exercises all four of pedal_decode_frame's out-of-range payload-field guards (global_color, active_bank, armed_track, track_leds[i]), each asserting decode rejection.

SUCCESS CRITERIA:
- test_malformed_frames_are_rejected() contains a CHECK asserting decode fails for an out-of-range global_color | verify: grep -n "global_color = PEDAL_GLOBAL_COUNT" firmware/test/test_pedal_protocol.c
- test_malformed_frames_are_rejected() contains a CHECK asserting decode fails for an out-of-range active_bank | verify: grep -n "active_bank = 2" firmware/test/test_pedal_protocol.c
- test_malformed_frames_are_rejected() contains a CHECK asserting decode fails for an out-of-range armed_track | verify: grep -n "armed_track = PEDAL_TRACK_COUNT" firmware/test/test_pedal_protocol.c
- test_malformed_frames_are_rejected() contains a CHECK asserting decode fails for an out-of-range track_leds[i] | verify: grep -n "track_leds\[0\] = PEDAL_LED_COUNT" firmware/test/test_pedal_protocol.c
- The host contract test builds cleanly and all checks (existing + new) pass | verify: cd firmware && gcc -std=c11 -Wall -I loopy_pedal test/test_pedal_protocol.c loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests && cd .. && /tmp/pedal_protocol_tests | tail -1 | grep -q "ALL PASSED"
- No production (non-test) firmware source changed | verify: git diff --name-only -- firmware/loopy_pedal | grep -q . && exit 1 || exit 0
- No CI workflow files changed | verify: git diff --name-only -- .github | grep -q . && exit 1 || exit 0

NON-GOALS:
- Modifying pedal_protocol.c's guard logic (it is already correct; this is a test-only gap).
- Wiring test_pedal_protocol.c into CI (handled by a separate, parallel effort).
- Adding coverage for anything beyond these four specific range guards.

VERIFICATION COMMAND: grep -n "global_color = PEDAL_GLOBAL_COUNT" firmware/test/test_pedal_protocol.c && grep -n "active_bank = 2" firmware/test/test_pedal_protocol.c && grep -n "armed_track = PEDAL_TRACK_COUNT" firmware/test/test_pedal_protocol.c && grep -n "track_leds\[0\] = PEDAL_LED_COUNT" firmware/test/test_pedal_protocol.c && (cd firmware && gcc -std=c11 -Wall -I loopy_pedal test/test_pedal_protocol.c loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests && cd .. && /tmp/pedal_protocol_tests | tail -1 | grep -q "ALL PASSED")
```

## Context

- `firmware/loopy_pedal/pedal_protocol.h` defines the enums used for the
  boundary values: `PEDAL_GLOBAL_COUNT = 5`, `PEDAL_TRACK_COUNT = 8`,
  `PEDAL_LED_COUNT = 3`. `active_bank`'s valid range (0 or 1) is a literal
  `bank > 1` check, not enum-backed.
- `test_malformed_frames_are_rejected()` (lines ~164-193) already reads the
  `idle_rec` fixture once (`bytes`/`len`) and decodes it into `f` at line 172
  (`CHECK(pedal_decode_frame(bytes, len, &f) == 1)`), proving it's a
  known-good, checksum-valid frame. That decoded `f` is the base for all four
  new mutations — no second fixture read needed.
- `pedal_encode_frame()` (pedal_protocol.c ~line 53) performs no range
  validation on encode — it packs whatever value is in the `pedal_frame`
  struct. This lets us mutate a decoded-good frame's field to an
  out-of-range value, re-encode it (producing a checksum-valid, correctly 7-bit
  packed message), and feed that back into `pedal_decode_frame`, which must
  then reject it purely because of the range guard under test — isolating
  exactly the behavior being tested, with no manual packed-byte-offset math.
- Per the brainstorm doc
  (`docs/brainstorm/2026-07-13-test-pedal-protocol-range-guard-coverage-brainstorm-doc.md`),
  boundary values (exactly one past the last legal value) are used rather than
  arbitrary large ones, since they're the strictest test of the `>=`/`>`
  comparisons.

## MVP

Insert the following block into `test_malformed_frames_are_rejected()` in
`firmware/test/test_pedal_protocol.c`, after the existing truncation checks
(after line 192, i.e. right before the function's closing brace) — reusing the
`f` frame already decoded at line 172 as the known-good base. It introduces two
new locals (`reencoded`, `mutated`); it does not reuse the existing `bad` byte
buffer, since this approach mutates the decoded struct rather than the raw
packed bytes.

```c
  /* Out-of-range payload fields (checksum-valid, correctly-framed, but a
   * field value the decoder must still reject). Mutate a copy of the
   * known-good decoded frame, re-encode it (pedal_encode_frame does not
   * itself validate ranges), and confirm decode now rejects it. */
  uint8_t reencoded[PEDAL_FRAME_MAX_BYTES];
  pedal_frame mutated;

  mutated = f;
  mutated.global_color = PEDAL_GLOBAL_COUNT; /* one past the last valid color */
  int rlen = pedal_encode_frame(&mutated, reencoded);
  CHECK(pedal_decode_frame(reencoded, rlen, &f) == 0);

  mutated = f;
  mutated.active_bank = 2; /* only 0 (A) and 1 (B) are valid */
  rlen = pedal_encode_frame(&mutated, reencoded);
  CHECK(pedal_decode_frame(reencoded, rlen, &f) == 0);

  mutated = f;
  mutated.armed_track = PEDAL_TRACK_COUNT; /* one past the last valid track */
  rlen = pedal_encode_frame(&mutated, reencoded);
  CHECK(pedal_decode_frame(reencoded, rlen, &f) == 0);

  mutated = f;
  mutated.track_leds[0] = PEDAL_LED_COUNT; /* one past the last valid LED */
  rlen = pedal_encode_frame(&mutated, reencoded);
  CHECK(pedal_decode_frame(reencoded, rlen, &f) == 0);
```

Notes on the snippet above:
- After each `CHECK(... == 0)` call, `f` is *not* overwritten with valid data
  (decode failed, so `pedal_decode_frame` must leave `*out` untouched per its
  contract of "the caller keeps its last good frame") — reassigning
  `mutated = f` at the top of the next block reuses the still-good `f` from
  line 172, so each of the four mutations is independent and starts from the
  same known-good baseline. Verify this assumption holds by reading
  `pedal_decode_frame`'s early-return behavior once more during implementation;
  if it turns out `f` could be partially mutated on a failed decode, decode
  the `idle_rec` fixture fresh (`pedal_decode_frame(bytes, len, &f)`) at the
  top of each of the four new blocks instead — one extra line per block, same
  outcome.
- `int rlen` is declared mid-block (C99/C11-style, matching the file's
  existing `-std=c11` build flag and its other for-loop-scoped declarations).

## References

- Brainstorm doc: `docs/brainstorm/2026-07-13-test-pedal-protocol-range-guard-coverage-brainstorm-doc.md`
- Guard logic under test: `firmware/loopy_pedal/pedal_protocol.c` lines 109-117
- Test file: `firmware/test/test_pedal_protocol.c`, function
  `test_malformed_frames_are_rejected()` at line 164
- Build/run command: `firmware/README.md` lines 119-125
