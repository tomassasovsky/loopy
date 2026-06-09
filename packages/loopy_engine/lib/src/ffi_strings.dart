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
/// char array [dst], truncating to fit (one byte reserved for the terminator).
void writeNativeString(
  Array<Char> dst,
  String value, {
  int capacity = kNativeStringCapacity,
}) {
  final bytes = utf8.encode(value);
  final length = bytes.length < capacity - 1 ? bytes.length : capacity - 1;
  for (var i = 0; i < length; i++) {
    dst[i] = bytes[i];
  }
  dst[length] = 0;
}
