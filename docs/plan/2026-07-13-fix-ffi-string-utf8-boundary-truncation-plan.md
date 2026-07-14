---
title: writeNativeString can truncate mid-UTF-8-character at the capacity boundary
type: fix
date: 2026-07-13
---

## writeNativeString can truncate mid-UTF-8-character at the capacity boundary - Minimal

`writeNativeString` in `packages/loopy_engine/lib/src/ffi_strings.dart`
truncates a UTF-8-encoded byte array to `capacity - 1` bytes by raw byte
count, with no check for whether the cut lands on a UTF-8 character boundary.
A non-ASCII device id/name/driver string (`asioDriver`, `playbackDeviceId`,
`captureDeviceId` on `EngineConfig`, or device `id`/`name` from
`le_device_info`) whose encoded length straddles the capacity cap has its
trailing multi-byte sequence split. `readNativeString`'s
`utf8.decode(bytes, allowMalformed: true)` then silently substitutes a U+FFFD
replacement character for the truncated tail instead of cleanly dropping the
partial character.

Fix: after computing the raw byte-count cut, scan backward while the byte at
the cut point is a UTF-8 continuation byte (`0x80`–`0xBF`), backing off the
cut to the start of that multi-byte sequence, capped at 3 bytes of backward
scan (the max continuation-byte run in a 4-byte UTF-8 sequence).

## Success Criteria

```success-criteria
GOAL: writeNativeString never splits a multi-byte UTF-8 character when truncating to fit capacity, so readNativeString never emits a U+FFFD replacement character for a truncated tail that writeNativeString produced.

SUCCESS CRITERIA:
- writeNativeString backs off the truncation length to a whole UTF-8 code-point boundary instead of a raw byte-count cut | verify: manual inspect packages/loopy_engine/lib/src/ffi_strings.dart to confirm the backward continuation-byte scan is present before the truncation loop
- A new unit test writes a string with a multi-byte character straddling the capacity boundary, round-trips it through writeNativeString -> readNativeString, and asserts the result contains no U+FFFD replacement character | verify: /Users/Tomas/development/flutter/bin/flutter test packages/loopy_engine/test/ffi_strings_test.dart
- Existing EngineConfig/ffi_strings-adjacent tests still pass (no regression to ASCII truncation or empty-string handling) | verify: /Users/Tomas/development/flutter/bin/flutter test packages/loopy_engine/test/engine_config_test.dart
- Static analysis is clean on the changed files | verify: /Users/Tomas/development/flutter/bin/flutter analyze packages/loopy_engine/lib/src/ffi_strings.dart packages/loopy_engine/test/ffi_strings_test.dart

NON-GOALS:
- Changing readNativeString's decode behavior (allowMalformed / replacement-character handling) — the write-side fix prevents split characters from ever being written, making this unnecessary
- Fixing any equivalent truncation logic on the native (C/C++) side of the engine, if it exists independently
- Any other findings from the same code-review pass (handled by separate parallel worktrees)

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test packages/loopy_engine/test/ffi_strings_test.dart packages/loopy_engine/test/engine_config_test.dart && /Users/Tomas/development/flutter/bin/flutter analyze packages/loopy_engine/lib/src/ffi_strings.dart packages/loopy_engine/test/ffi_strings_test.dart
```

## Context

- File: `packages/loopy_engine/lib/src/ffi_strings.dart` (lines ~27-38 for
  `writeNativeString`; `readNativeString` above it is untouched).
- `kNativeStringCapacity = 256` is the shared capacity constant for
  `le_device_info.id`/`name` and `le_config.playback_device_id`/
  `capture_device_id` (see doc comment at top of file). `le_plugin_desc.name`/
  `vendor` use capacity 128 and `.path` uses 1024 — the fix must work for any
  `capacity` value, not just the default 256.
- Callers of `writeNativeString`: `packages/loopy_engine/lib/src/engine_config.dart`
  lines 107-109 (`playback_device_id`, `capture_device_id`, `asio_driver`).
- Existing test file `packages/loopy_engine/test/engine_config_test.dart`
  exercises `readNativeString`/`writeNativeString` round-trips via
  `calloc<le_config>()` — follow this pattern (import `dart:ffi`,
  `package:ffi/ffi.dart`, `package:loopy_engine/src/ffi_strings.dart`, and the
  generated bindings) for the new test.
- No `ffi_strings_test.dart` exists yet; `packages/loopy_engine/test/` is
  flat (no subdirectories) — new test file goes directly at
  `packages/loopy_engine/test/ffi_strings_test.dart`.
- Test runner gotcha (project memory): the very_good_cli MCP `test` tool is
  broken in this repo (exit 69). Use the absolute path
  `/Users/Tomas/development/flutter/bin/flutter test <path>` directly (a repo
  hook blocks the bare `flutter`/`dart` command but not an absolute path).

## MVP

**Design note (post-review):** the initial sketch used a backward
continuation-byte scan (`bytes[length] & 0xC0 == 0x80`). The plan's technical
review (code-simplicity-review-agent) flagged this as correct but needlessly
intricate — the author's own prose hedged with "verify this logic... adjust
indices if the off-by-one differs." The plan now uses a simpler
**forward, whole-code-point accumulation** over `value.runes` instead: it
cannot split a character by construction, since each loop iteration commits
one full rune's bytes or none at all. This is the version to implement.

Replace the body of `writeNativeString` in
`packages/loopy_engine/lib/src/ffi_strings.dart`:

```dart
void writeNativeString(
  Array<Char> dst,
  String value, {
  int capacity = kNativeStringCapacity,
}) {
  final maxBytes = capacity - 1;
  final bytes = <int>[];
  for (final rune in value.runes) {
    final runeBytes = utf8.encode(String.fromCharCode(rune));
    if (bytes.length + runeBytes.length > maxBytes) break;
    bytes.addAll(runeBytes);
  }
  for (var i = 0; i < bytes.length; i++) {
    dst[i] = bytes[i];
  }
  dst[bytes.length] = 0;
}
```

This walks `value` one Unicode code point (`rune`) at a time, encoding just
that rune to UTF-8 and only appending it to the output buffer if doing so
would not exceed `maxBytes`. Because a rune's UTF-8 encoding is always
appended atomically (all its bytes or none), the accumulated `bytes` can
never end mid-character — truncation always lands on a whole code-point
boundary. Pure-ASCII strings behave exactly as before (each rune is 1 byte,
so the cut point matches the old raw byte-count behavior when no multi-byte
character is involved).

**Test buffer allocation correction (post-review):** the vgv-review-agent
found that `calloc<Char>(capacity)` does **not** work — `Array<Char>` in
`dart:ffi` only exists as an inline field inside a generated `Struct`; there
is no standalone `Array<Char>` allocation. Follow the existing convention in
`engine_config_test.dart`: allocate the whole struct with
`calloc<le_config>()` and pass `.ref.playback_device_id` (or `.ref.asio_driver`,
etc. — capacity 256) to `writeNativeString`/`readNativeString`. If a
non-default capacity needs covering, `calloc<le_plugin_desc>()` exposes
`.ref.name`/`.ref.vendor` (capacity 128) and `.ref.path` (capacity 1024) —
but this is optional; testing purely against the default `kNativeStringCapacity`
(256, via `le_config`) is sufficient to prove the fix.

Add `packages/loopy_engine/test/ffi_strings_test.dart` with at least:

- A test with a string built to make `utf8.encode(value).length >= capacity`
  and a multi-byte character (e.g. `é`, 2 bytes) positioned so the raw
  `capacity - 1` byte cut would land mid-character. Allocate a
  `calloc<le_config>()`, pass `.ref.playback_device_id` through
  `writeNativeString` then `readNativeString`, assert the result does not
  contain `'�'`, and free the pointer (in a `try`/`finally`).
- A regression test that pure-ASCII truncation still behaves as before
  (result length is exactly `capacity - 1` when the ASCII input is longer
  than capacity).
- A regression test that a string shorter than capacity round-trips
  unchanged (no truncation path taken).

## References

- Issue found by multi-agent code review, re-verified at commit `f3f5b76`
  (origin/master HEAD).
- Brainstorm doc: `docs/brainstorm/2026-07-13-ffi-strings-utf8-boundary-truncation-brainstorm-doc.md`
