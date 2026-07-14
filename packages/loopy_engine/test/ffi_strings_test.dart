import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/src/ffi_strings.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';

void main() {
  group('writeNativeString / readNativeString round trip', () {
    test(
      'a multi-byte character straddling the capacity boundary is dropped '
      'whole, not split into a replacement character',
      () {
        // 254 ASCII bytes + a 2-byte 'é' (0xC3 0xA9) = 256 encoded bytes,
        // one more than the 255 bytes available (kNativeStringCapacity of
        // 256, minus 1 for the NUL terminator). The raw byte-count cut used
        // before this fix would keep the 'é' lead byte (0xC3) without its
        // continuation byte, and readNativeString's
        // utf8.decode(allowMalformed: true) would then substitute a U+FFFD
        // replacement character for that dangling lead byte.
        final value = '${'a' * 254}é';
        final ptr = calloc<le_config>();
        try {
          writeNativeString(ptr.ref.playback_device_id, value);
          final written = readNativeString(ptr.ref.playback_device_id);
          expect(written.contains('\u{FFFD}'), isFalse);
          expect(written, 'a' * 254);
        } finally {
          calloc.free(ptr);
        }
      },
    );

    test('pure-ASCII truncation still cuts at capacity - 1 bytes', () {
      final value = 'x' * 400;
      final ptr = calloc<le_config>();
      try {
        writeNativeString(ptr.ref.playback_device_id, value);
        final written = readNativeString(ptr.ref.playback_device_id);
        expect(written.length, kNativeStringCapacity - 1);
        expect(written, 'x' * (kNativeStringCapacity - 1));
      } finally {
        calloc.free(ptr);
      }
    });

    test('a string shorter than capacity round-trips unchanged', () {
      const value = 'short-value';
      final ptr = calloc<le_config>();
      try {
        writeNativeString(ptr.ref.playback_device_id, value);
        final written = readNativeString(ptr.ref.playback_device_id);
        expect(written, value);
      } finally {
        calloc.free(ptr);
      }
    });

    test(
      'a multi-byte character that fits exactly at the boundary is kept '
      'whole',
      () {
        // 253 ASCII bytes + a 2-byte 'é' = 255 encoded bytes, exactly the
        // available capacity (no truncation needed at all).
        final value = '${'a' * 253}é';
        final ptr = calloc<le_config>();
        try {
          writeNativeString(ptr.ref.playback_device_id, value);
          final written = readNativeString(ptr.ref.playback_device_id);
          expect(written.contains('\u{FFFD}'), isFalse);
          expect(written, value);
        } finally {
          calloc.free(ptr);
        }
      },
    );

    test(
      'a 4-byte surrogate-pair character straddling the capacity boundary '
      'is dropped whole, not split into a replacement character',
      () {
        // 253 ASCII bytes + a 4-byte '😀' (U+1F600, backed by a UTF-16
        // surrogate pair in the Dart string) = 257 encoded bytes, two more
        // than the 255 bytes available. This exercises the surrogate-pair
        // path of String.runes, distinct from the 2-byte 'é' cases above: an
        // implementation that iterated codeUnits instead of runes would
        // split the surrogate pair itself and could still pass the 2-byte
        // cases while failing here.
        final value = '${'a' * 253}😀';
        final ptr = calloc<le_config>();
        try {
          writeNativeString(ptr.ref.playback_device_id, value);
          final written = readNativeString(ptr.ref.playback_device_id);
          expect(written.contains('\u{FFFD}'), isFalse);
          expect(written, 'a' * 253);
        } finally {
          calloc.free(ptr);
        }
      },
    );

    test(
      'a 4-byte surrogate-pair character that fits exactly at the boundary '
      'is kept whole',
      () {
        // 251 ASCII bytes + a 4-byte '😀' = 255 encoded bytes, exactly the
        // available capacity (no truncation needed at all).
        final value = '${'a' * 251}😀';
        final ptr = calloc<le_config>();
        try {
          writeNativeString(ptr.ref.playback_device_id, value);
          final written = readNativeString(ptr.ref.playback_device_id);
          expect(written.contains('\u{FFFD}'), isFalse);
          expect(written, value);
        } finally {
          calloc.free(ptr);
        }
      },
    );
  });
}
