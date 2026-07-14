---
date: 2026-07-13
topic: test-pedal-protocol-range-guard-coverage
---

# Pedal protocol: cover the four out-of-range decode guards

## What We're Building

`pedal_decode_frame()` (firmware/loopy_pedal/pedal_protocol.c, ~line 107-117) has
four defensive range checks that reject an otherwise checksum-valid frame:
`global_color >= PEDAL_GLOBAL_COUNT`, `active_bank > 1`,
`armed_track >= PEDAL_TRACK_COUNT`, and any `track_leds[i] >= PEDAL_LED_COUNT`.
None of these four branches is exercised by
`firmware/test/test_pedal_protocol.c` — its only malformed-frame test
(`test_malformed_frames_are_rejected`) covers checksum corruption, wrong
protocol version, wrong manufacturer id, and truncation, but never an
out-of-range payload value. We're adding four new assertions — one per guard —
to that same test function, each starting from a known-good decoded frame,
corrupting exactly one field to the smallest out-of-range value, and asserting
`pedal_decode_frame` rejects the re-encoded result.

This is a pure test-addition task: no production code in `pedal_protocol.c`
changes, no CI wiring (a separate parallel effort is adding this suite to CI).

## Why This Approach

Two ways to construct a malformed frame for each guard were considered:

**A. Decode a known-good fixture into a `pedal_frame`, mutate the one field in
the struct, re-encode with the already-present `pedal_encode_frame()`, then
attempt to decode that output and assert rejection.** (Recommended)

- Pros: no manual byte-offset math against the packed/7-bit-clean wire format;
  reuses functions already linked into the test binary; mirrors the file's
  existing `decode_fixture` round-trip idiom (decode -> mutate/inspect ->
  re-encode); trivially correct because `pedal_encode_frame` is not aware of
  the range guards, so it faithfully packs whatever out-of-range value we put
  in the struct, and checksum/7-bit-clean framing come out correct by
  construction.
- Cons: indirectly depends on `pedal_encode_frame` being correct, but every
  other test in the file already depends on it via `decode_fixture`, so this
  isn't a new dependency.
- Best when: the goal is "prove the decoder's range guard fires," not "prove a
  hand-crafted byte string is correctly parsed."

**B. Hand-compute the packed-byte offset for each field (e.g. payload[1] for
`global_color`) against the existing `idle_rec` fixture bytes, XOR/OR a bad
value directly into the raw SysEx buffer, and fix up the checksum byte to keep
it checksum-valid.**

- Pros: exercises the unpack path with literal wire bytes, closest to "a real
  corrupted MIDI cable byte."
- Cons: requires re-deriving `pedal_pack7`'s group boundaries (8/8/4-byte
  groups for the 17-byte payload) by hand for every field, is fragile to any
  future payload layout change, and is meaningfully more code/complexity for
  no additional coverage value — the decode guard doesn't care how the
  out-of-range byte got into the unpacked payload.

Approach A was chosen: it's simpler, matches the file's established idiom, and
gives byte-for-byte identical coverage of the guards under test with far less
risk of an off-by-one in test code itself (which would be tested by nothing).

## Key Decisions

- **Reuse the already-decoded `idle_rec` frame** in
  `test_malformed_frames_are_rejected` (it's decoded once at the top of that
  function already) as the "known-good" base frame for all four mutations,
  rather than adding a second fixture read — keeps the new cases co-located
  with the existing malformed-frame checks and avoids duplicate I/O.
- **Pick boundary out-of-range values**, i.e. exactly one past the last legal
  value (`PEDAL_GLOBAL_COUNT`, `2` for active_bank, `PEDAL_TRACK_COUNT`,
  `PEDAL_LED_COUNT`) rather than arbitrary large ones (e.g. 255) — this is the
  strictest test of the `>=`/`>` comparison and matches how the Dart-side
  `pedal_codec_test.dart` likely tests its equivalent guards (boundary values
  catch off-by-one bugs; large values only catch "totally broken" bugs).
- **New cases live inside `test_malformed_frames_are_rejected`**, not a new
  test function — the four new checks are thematically identical to the
  existing ones in that function ("this exact class of malformed frame must be
  rejected"), and the file's convention is one test function per fixture/topic
  cluster rather than one function per assertion.
- **Do not touch `pedal_protocol.c` or any CI file** — strictly additive to
  the C test file, per the assigned scope.

## Open Questions

None blocking — this is a narrowly-scoped test-gap fix with a single
reasonable implementation approach. If a future reviewer prefers hand-crafted
raw-byte mutation (Approach B) for one or more cases for closer-to-the-wire
fidelity, that can be layered in later without conflicting with this change.
