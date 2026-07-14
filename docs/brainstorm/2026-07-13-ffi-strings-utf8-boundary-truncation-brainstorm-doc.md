---
date: 2026-07-13
topic: ffi-strings-utf8-boundary-truncation
---

# Fix UTF-8 boundary truncation in writeNativeString

## What We're Building

`writeNativeString` in `packages/loopy_engine/lib/src/ffi_strings.dart` truncates
UTF-8-encoded strings to `capacity - 1` bytes by raw byte count, with no regard
for whether the cut point lands inside a multi-byte UTF-8 character. When a
non-ASCII string (e.g. `asioDriver`, `playbackDeviceId`, `captureDeviceId` on
`EngineConfig`, or a device `id`/`name` from `le_device_info`) has its encoded
length straddle the capacity boundary, the trailing bytes of the split
character get written to the native buffer. `readNativeString`'s
`utf8.decode(bytes, allowMalformed: true)` then silently turns that dangling
partial sequence into a U+FFFD replacement character, rather than cleanly
dropping the whole character that didn't fit.

The fix: before truncating, back off the cut point to the start of any
multi-byte sequence that would otherwise be split, so `writeNativeString`
always truncates on a whole UTF-8 code-point boundary. Add a unit test that
writes a string with a multi-byte character straddling the capacity boundary
and asserts the round trip through `writeNativeString` → `readNativeString`
never produces `�`.

## Why This Approach

Considered three approaches:

1. **Manual continuation-byte back-off (chosen).** After computing the raw
   byte-count cut (`length`), scan backward while `bytes[length]` is a UTF-8
   continuation byte (`0x80`–`0xBF`), decrementing `length` each time, capped
   at scanning back at most 3 bytes (the max continuation-byte run for a
   4-byte UTF-8 sequence). This mirrors exactly the check the issue's
   suggested-fix direction describes, requires no new imports, is O(1)
   (bounded loop of ≤3 iterations), and keeps the function allocation-free.

2. **Decode-then-re-encode-until-it-fits.** Repeatedly call
   `utf8.decode(bytes.sublist(0, n), allowMalformed: false)` shrinking `n`
   until decoding succeeds without throwing, then re-encode. Correct, but does
   redundant decode/encode work in a hot-ish path (called on every config
   write) and is more code than the manual scan for the same result.

3. **Use `Utf8Decoder` in a streaming mode with `allowMalformed: false` to
   detect the cut, catching `FormatException` to retry with `length - 1`.**
   Functionally similar to #2 but leans on exceptions for control flow, which
   is un-idiomatic here and adds decode overhead just to determine an offset
   we can compute directly from the byte pattern.

Approach 1 was chosen: it's the simplest, matches the codebase's existing
low-level/no-allocation style in this file, and directly implements the fix
direction suggested in the verified issue.

## Key Decisions

- **Backward scan bound of 3 bytes**: A UTF-8 continuation byte run for a
  split character is at most 3 bytes (start of a 4-byte sequence, with 3
  continuation bytes following the lead byte). If we scan back 3 bytes and
  still see a continuation byte, treat that as a malformed/already-truncated
  input rather than continuing indefinitely — this cannot happen for
  correctly-encoded UTF-8 input from `utf8.encode`, so the bound is just a
  defensive safety cap, not an expected code path.
- **No API signature change**: `writeNativeString`'s parameters
  (`Array<Char> dst, String value, {int capacity}`) stay the same. This is a
  pure internal fix to the truncation calculation; callers
  (`EngineConfig.toNative` in `lib/src/engine_config.dart`) are unaffected.
- **Test file location**: no existing `ffi_strings_test.dart` exists; the
  `test/` directory in `packages/loopy_engine` is flat (no subdirectories), so
  the new test file goes at `packages/loopy_engine/test/ffi_strings_test.dart`,
  following the flat convention already used by sibling test files
  (`engine_config_test.dart`, `audio_device_test.dart`, etc.).
- **Test approach**: allocate a native `Array<Char>` via `calloc<le_config>()`
  (or a raw `calloc<Char>(capacity)` — whichever is simpler to wire up) sized
  to `kNativeStringCapacity` (256), construct a string whose UTF-8 encoding is
  exactly at/over 255 bytes with a 2-byte (or more) character straddling that
  boundary (e.g. repeat an ASCII prefix then end with a run of a 2-byte
  character like `é`), call `writeNativeString`, then `readNativeString`, and
  assert the result contains no `�` and is a valid prefix of the original
  string (i.e. `utf8.encode(result).length <= capacity - 1` and the result
  equals a whole-character prefix of the input, not a partial character).
- **Scope discipline**: this fix touches only `writeNativeString` in
  `ffi_strings.dart` plus its new test file. `readNativeString` is untouched
  — with the write-side fix in place, `readNativeString` will never encounter
  a split character from a `writeNativeString`-written buffer in the first
  place, so no change is needed there. Native-side (C/C++) truncation, if any
  exists independently, is out of scope for this fix (the issue is scoped to
  the Dart FFI helper).

## Open Questions

- None blocking. One assumption worth flagging for the plan/build phase: the
  fix assumes `bytes` (the output of `utf8.encode`) is always well-formed
  UTF-8 (true for any Dart `String`, since Dart strings are UTF-16 and
  `utf8.encode` cannot produce a malformed continuation-byte sequence from
  valid input), so the backward-scan bound of 3 is provably sufficient and
  will never be exceeded in practice.
