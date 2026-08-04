import 'dart:convert';
import 'dart:ffi';

/// Capacity, in bytes, of the native fixed-size `char[256]` string fields:
/// `le_device_info.id` / `name` and `le_config.playback_device_id` /
/// `capture_device_id`. The single source of truth shared by the read and
/// write helpers below so the Dart side cannot drift from the C struct.
const int kNativeStringCapacity = 256;

/// Reads a native fixed-size `char[capacity]` field as a UTF-8 string, stopping
/// at the NUL terminator the native side always writes.
String readNativeString(
  Array<Char> array, {
  int capacity = kNativeStringCapacity,
}) {
  final bytes = <int>[];
  for (var i = 0; i < capacity; i++) {
    final byte = array[i] & 0xff;
    if (byte == 0) break;
    bytes.add(byte);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Writes [value] as a NUL-terminated UTF-8 C string into the native fixed-size
/// char array [dst], truncating to fit (one byte reserved for the
/// terminator).
///
/// Truncation proceeds one Unicode code point (rune) at a time so a
/// multi-byte UTF-8 character is never split at the capacity boundary: each
/// rune's encoded bytes are appended atomically (all of them, or none),
/// rather than cutting the encoded byte array at a raw byte count.
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
