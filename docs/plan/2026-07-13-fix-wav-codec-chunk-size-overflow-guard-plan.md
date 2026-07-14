---
title: WavCodec.encodeFloat32 guard against 32-bit chunk-size overflow
type: fix
date: 2026-07-13
---

## WavCodec.encodeFloat32 guard against 32-bit chunk-size overflow - Minimal

`WavCodec.encodeFloat32` (`packages/wav_codec/lib/src/wav.dart:35-64`) writes
the RIFF chunk size (`36 + dataBytes`) and `data` chunk size (`dataBytes`)
into 32-bit header fields via `ByteData.setUint32`, which silently wraps
(truncates mod 2^32) rather than throwing when the value exceeds
`0xFFFFFFFF`. Once encoded audio data exceeds ~4 GiB (a few hours of
recording, realistic for Loopy's own performance-recording feature), the
header lies about the file's size while the underlying byte buffer is the
correct, full length. Downstream readers that trust the header — including
this package's own `decodeFloat32`, which derives sample count from the
header's `dataSize` field — will misparse the file: truncating audio or
throwing a confusing error far from the point where the real corruption
happened.

This fix adds an explicit bounds check that runs *before* any header bytes
are written (and before the output buffer is allocated), throwing a clear
`ArgumentError` the instant the precondition is violated, instead of
producing a silently corrupt file.

See `docs/brainstorm/2026-07-13-wav-codec-encode-size-overflow-guard-brainstorm-doc.md`
for the alternatives considered (custom exception type, fallible/Result
signature) and why a stock `ArgumentError` with no signature change was
chosen — it mirrors `decodeFloat32`'s existing convention of throwing stock
Dart exceptions rather than a custom hierarchy, and keeps callers in
`performance_repository`/`session_repository` untouched, per the issue's
instruction to stay narrowly scoped to this one bug.

## Success Criteria

```success-criteria
GOAL: WavCodec.encodeFloat32 throws a clear ArgumentError instead of silently
writing a corrupt (wrapped) 32-bit chunk-size header when the encoded data
would exceed the format's 4 GiB limit, with no change to its public
signature or to any call site.

SUCCESS CRITERIA:
- encodeFloat32 throws ArgumentError (not a silently-wrapped header) when 36 + dataBytes would exceed 0xFFFFFFFF | verify: cd packages/wav_codec && /Users/Tomas/development/flutter/bin/dart test test/wav_test.dart
- The exact boundary is correct: the largest dataBytes that keeps `36 + dataBytes <= 0xFFFFFFFF` succeeds, and one byte more throws | verify: cd packages/wav_codec && /Users/Tomas/development/flutter/bin/dart test test/wav_test.dart --name "chunk size"
- Existing encode/decode round-trip and malformed-input tests still pass unmodified | verify: cd packages/wav_codec && /Users/Tomas/development/flutter/bin/dart test
- No call site in performance_repository or session_repository changed (fix is confined to wav_codec) | verify: git diff --name-only master... | grep -v '^packages/wav_codec/' | grep -v '^docs/' ; test $? -ne 0
- Static analysis is clean on the touched package | verify: cd packages/wav_codec && /Users/Tomas/development/flutter/bin/dart analyze

NON-GOALS:
- Adding recording-duration limiting or file-splitting upstream in
  performance_repository/session_repository so callers never approach the
  4 GiB threshold in the first place — that is a separate, larger
  product-level feature explicitly called out as future follow-up.
- Introducing a new custom exception hierarchy (e.g. WavEncodingException)
  for wav_codec — out of scope; a stock ArgumentError is sufficient and
  consistent with decodeFloat32's existing FormatException convention.
- Changing encodeFloat32's return type to a Result/nullable — no caller
  currently branches on a fallible result, and adding one would touch
  call sites outside the scope of this fix.

VERIFICATION COMMAND: cd packages/wav_codec && /Users/Tomas/development/flutter/bin/dart analyze && /Users/Tomas/development/flutter/bin/dart test
```

## Context

- File to change: `packages/wav_codec/lib/src/wav.dart`
- Test file to extend: `packages/wav_codec/test/wav_test.dart`
- `wav_codec` is a pure-Dart package (no Flutter dependency) — uses
  `package:test`, run via plain `dart test`, not `flutter test` or the
  `very_good` test runner (which is broken per project memory
  `loopy-test-runner-gotcha.md` — that gotcha is about the Flutter-side
  runner; this package predates/avoids that entirely by being pure Dart).
- `meta` is already a dependency of `wav_codec` (used for `@immutable` on
  `WavData`), so `@visibleForTesting` is available with no pubspec change.
- **Naming**: `checkDataSize` mirrors Dart core's own `ArgumentError.checkNotNull` —
  a static "check" method that throws on precondition violation is an
  established Dart idiom, not a boolean predicate; kept as-is after
  technical review raised it as a nit.
- **Error message**: uses a plain `ArgumentError(message)` rather than
  `ArgumentError.value(dataBytes, 'dataBytes', ...)` — `dataBytes` is not a
  parameter of the public `encodeFloat32` signature (it's derived
  internally as `samples.length * 4`), so naming it as the invalid
  "argument" via `.value`/`.name` would be misleading to a caller inspecting
  `error.name`. The message text still states the computed byte count and
  the limit for diagnosability.
- **Accepted testing gap**: the boundary is tested via the extracted
  `checkDataSize(int)` helper directly, not by calling `encodeFloat32` with
  an actual ~4 GiB `Float32List` — allocating that in a unit test is
  impractical for CI. `encodeFloat32` calls the exact same helper
  internally, so this is testing the real guard logic, not a parallel
  reimplementation.
- Callers of `encodeFloat32` (for reference only — not modified by this fix):
  `packages/performance_repository/lib/src/performance_repository.dart:387,399,478`
  and `packages/session_repository/lib/src/session_repository.dart:213,231,314,336`.
  None currently wrap the call in try/catch; this fix does not add any.

## MVP

In `packages/wav_codec/lib/src/wav.dart`:

```dart
abstract final class WavCodec {
  static const int _headerBytes = 44;

  // Largest data-chunk byte count for which the RIFF chunk-size field
  // (36 + dataBytes) still fits in an unsigned 32-bit int. Beyond this,
  // ByteData.setUint32 would silently wrap instead of throwing.
  static const int _maxDataBytes = 0xFFFFFFFF - 36;

  /// Throws [ArgumentError] if [dataBytes] would overflow the WAV header's
  /// 32-bit chunk-size fields. Exposed (`@visibleForTesting`) so the exact
  /// boundary can be tested without allocating a ~4 GiB sample buffer.
  @visibleForTesting
  static void checkDataSize(int dataBytes) {
    if (dataBytes > _maxDataBytes) {
      throw ArgumentError(
        'WAV data size of $dataBytes bytes (from `samples`) exceeds the '
        '32-bit RIFF/data chunk-size limit of $_maxDataBytes bytes',
      );
    }
  }

  static Uint8List encodeFloat32({
    required Float32List samples,
    required int sampleRate,
    required int channels,
  }) {
    final dataBytes = samples.length * 4;
    checkDataSize(dataBytes);
    final out = Uint8List(_headerBytes + dataBytes);
    // ...unchanged from here down...
  }
}
```

In `packages/wav_codec/test/wav_test.dart`, add a new group/tests:

```dart
group('encodeFloat32 chunk-size guard', () {
  test('accepts dataBytes exactly at the 32-bit boundary', () {
    expect(() => WavCodec.checkDataSize(0xFFFFFFFF - 36), returnsNormally);
  });

  test('throws ArgumentError one byte past the 32-bit boundary', () {
    expect(
      () => WavCodec.checkDataSize(0xFFFFFFFF - 35),
      throwsArgumentError,
    );
  });
});
```

Note: test names should include "chunk size" (per the `verify` filter above)
— adjust the `--name` filter in Success Criteria to match whatever exact
test description is chosen if it differs from this sketch.

## References

- Brainstorm: `docs/brainstorm/2026-07-13-wav-codec-encode-size-overflow-guard-brainstorm-doc.md`
- Related project memory: `loopy-test-runner-gotcha.md` (very_good MCP
  runner is broken for Flutter packages — not applicable here since
  `wav_codec` is pure Dart and already tested via plain `dart test`).
