// A second, independent implementation of the state-frame wire format used by
// the tests. Re-deriving the 7-bit packing and checksum here (rather than
// calling the production codec) cross-checks `PedalCodec` against an
// independent encoder and lets tests craft deliberately malformed frames from
// arbitrary logical payloads.
import 'dart:typed_data';

/// Packs 8-bit [data] into 7-bit-clean MIDI bytes.
List<int> pack7(List<int> data) {
  final out = <int>[];
  for (var i = 0; i < data.length; i += 7) {
    final group = data.skip(i).take(7).toList();
    var msb = 0;
    for (var j = 0; j < group.length; j++) {
      if (group[j] & 0x80 != 0) msb |= 1 << j;
    }
    out
      ..add(msb)
      ..addAll(group.map((b) => b & 0x7F));
  }
  return out;
}

/// XOR checksum over already-packed bytes, masked to 7 bits.
int checksum7(List<int> packed) => packed.fold(0, (acc, b) => acc ^ b) & 0x7F;

/// Builds a full SysEx state frame from a 16-byte logical [payload].
Uint8List buildStateSysEx(
  List<int> payload, {
  int manufacturer = 0x7D,
  int version = 0x01,
  int type = 0x01,
}) {
  return buildFromPacked(
    pack7(payload),
    manufacturer: manufacturer,
    version: version,
    type: type,
  );
}

/// Builds a full SysEx state frame from already-[packed] bytes, computing a
/// matching checksum so callers can tamper individual packed bytes.
Uint8List buildFromPacked(
  List<int> packed, {
  int manufacturer = 0x7D,
  int version = 0x01,
  int type = 0x01,
}) {
  return Uint8List.fromList([
    0xF0,
    manufacturer,
    version,
    type,
    ...packed,
    checksum7(packed),
    0xF7,
  ]);
}

/// A minimal, valid 16-byte logical payload (all-off, bank A, armed track 0).
List<int> validPayload() => List<int>.filled(16, 0);
