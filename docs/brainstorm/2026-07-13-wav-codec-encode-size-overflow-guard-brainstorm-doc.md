---
date: 2026-07-13
topic: wav-codec-encode-size-overflow-guard
---

# WavCodec.encodeFloat32: guard against 32-bit chunk-size overflow

> Autonomous run: no live user was available for interactive dialogue. This
> doc records the decisions I made and the assumptions behind them so the
> planning phase can proceed without blocking. This is a single, narrowly
> scoped bug fix (1 of 21 parallelized fixes from a code review pass) — no
> other findings from that review are addressed here.

## What We're Building

`WavCodec.encodeFloat32` (`packages/wav_codec/lib/src/wav.dart`) writes the
RIFF chunk size and `data` chunk size as 32-bit little-endian fields via
`ByteData.setUint32`. Dart's `setUint32` silently wraps values that exceed
`0xFFFFFFFF` instead of throwing, so once encoded audio exceeds roughly 4 GiB
(a few hours of recording — realistic for Loopy's own performance-recording
feature), the header lies about the file's size while the actual byte buffer
is still the correct, full length. Any reader that trusts the header
(including this package's own `decodeFloat32`, which derives sample count
from the header's `dataSize` field) will misparse the file: truncating audio
or throwing, non-obviously, at read time — long after the silent corruption
actually happened at encode time.

The fix adds an explicit bounds check in `encodeFloat32` that runs before any
header bytes are written, and throws a clear, immediate `ArgumentError` if
`36 + dataBytes` (the RIFF chunk size) would exceed `0xFFFFFFFF`. This turns
a silent, delayed, confusing failure (corrupt file, weird decode error much
later) into a loud, immediate one at the moment the real problem occurs.

## Why This Approach

**Approach considered: throw a stock `ArgumentError` (recommended, chosen).**
`encodeFloat32` already has an implicitly fallible contract — nothing in its
current signature or docs promises it never throws, and its sibling
`decodeFloat32` already throws a stock `FormatException` (not a custom
package-level exception type) for its own error paths. `wav_codec` is a leaf
package with no existing custom-exception hierarchy of its own (custom
`sealed class ...Exception` hierarchies exist one layer up, in
`performance_repository` and `session_repository`, for *recoverable,
user-facing* failures that callers are expected to catch and present to the
user). An oversized buffer here is not a recoverable, user-actionable
condition in the same sense — it is a hard precondition violation on the
function's input (arguably a bug/gap in the caller for not bounding
recording duration, which is explicitly out of scope for this fix). Using
`ArgumentError` matches Dart idiom for "the argument you passed cannot be
satisfied" and requires zero signature changes and zero call-site changes at
`performance_repository`/`session_repository`, keeping this fix narrowly
scoped to the one file the issue names.

- Pros: minimal, idiomatic, symmetric with `decodeFloat32`'s existing
  stock-exception convention, no caller changes required, trivially testable.
- Cons: does not, by itself, give callers a recoverable path (e.g. "record
  shorter" or "split into multiple files") — but building that is a separate,
  larger feature (duration limiting/segmenting) explicitly flagged as future
  work by the issue, not something to bolt on here.
- Best when: the violation is a hard precondition on the function's own
  contract rather than a data-driven, catchable business failure.

**Approach considered: new typed `WavEncodingException` (rejected for this
fix).** Would follow the `SessionException`/`PerformanceException` sealed
pattern. Rejected because `wav_codec` currently has zero custom exception
types and decode errors already use a stock `FormatException` — introducing
a new custom hierarchy here would be an unrequested architectural change to
the package's error-handling convention, and no caller currently catches or
would catch a specific type (confirmed by grep: no try/catch around any
`encodeFloat32` call site). Keeping scope tight favors the stock exception.

**Approach considered: make `encodeFloat32` return a `Result`/nullable and
have callers branch (rejected).** Would require touching
`performance_repository.dart` and `session_repository.dart` call sites,
which the issue explicitly says to keep scoped/consistent rather than
rearchitect, and none of those call sites currently have any fallback
behavior for "couldn't write this WAV" (they're on write paths where the
only sane fallback is "fail loudly"). Out of scope for a narrow bug fix.

## Key Decisions

- **Guard location**: check happens in `encodeFloat32` itself, before the
  `Uint8List(_headerBytes + dataBytes)` allocation and before any header
  bytes are written — so no partial/garbage buffer is ever allocated or
  returned.
- **Threshold**: the binding constraint is the RIFF chunk size field
  (`36 + dataBytes`), which overflows before the bare `data` chunk size field
  does. Guard condition: throw when `36 + dataBytes > 0xFFFFFFFF`
  (equivalently `dataBytes > 0xFFFFFFFF - 36`).
- **Exception type**: `ArgumentError` (stock Dart), with a descriptive
  message stating the byte count and the 32-bit limit — matching
  `decodeFloat32`'s existing convention of throwing stock exceptions rather
  than inventing a new custom exception hierarchy in this leaf package.
- **No signature change**: `encodeFloat32`'s return type and parameters stay
  the same. It was already implicitly fallible; this just adds one more
  (loud, precise) way it can fail, consistent with `decodeFloat32` already
  throwing `FormatException`.
- **No caller changes**: `performance_repository.dart` and
  `session_repository.dart` are left untouched — adding duration-limiting or
  file-splitting logic upstream is a separate, larger feature explicitly
  called out as future follow-up by the issue, not part of this fix.
- **Testability**: rather than allocating a literal ~4 GiB `Float32List` in a
  test (memory-heavy, slow, environment-dependent), expose the size-check
  logic as a small `@visibleForTesting` static helper on `WavCodec` that
  takes the already-computed `dataBytes` integer directly (no sample array
  involved). The unit test calls this helper directly at and around the
  exact threshold (`0xFFFFFFFF - 36` bytes passes, `0xFFFFFFFF - 35` bytes
  throws), which is instant and allocation-free. `encodeFloat32` calls this
  same helper internally, so production behavior and the tested logic are
  identical, not just parallel implementations.
- **Existing tests untouched**: current passing-case tests in
  `packages/wav_codec/test/wav_test.dart` use tiny sample arrays and are
  unaffected by the new guard (its threshold is far above any array they
  construct).

## Open Questions

None blocking — this is a narrow, mechanical fix. Genuinely deferred (not
part of this fix, called out by the issue itself as follow-up):
recording-duration limiting/segmenting so callers avoid ever hitting this
threshold in the first place; that's a product-level decision affecting
`performance_repository`/`session_repository`, out of scope for a single
codec-layer bug fix.
