import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';

void _writeName(Pointer<le_loopback_info> ptr, String name) {
  final offset = sizeOf<le_loopback_info>() - 256;
  final bytes = Pointer<Uint8>.fromAddress(
    ptr.address + offset,
  ).asTypedList(256);
  final units = utf8.encode(name);
  bytes.setRange(0, units.length, units);
  bytes[units.length] = 0;
}

void main() {
  group('LoopbackKind.fromCode', () {
    test('maps each known code', () {
      expect(LoopbackKind.fromCode(0), LoopbackKind.none);
      expect(LoopbackKind.fromCode(1), LoopbackKind.wasapi);
      expect(LoopbackKind.fromCode(2), LoopbackKind.monitor);
      expect(LoopbackKind.fromCode(3), LoopbackKind.virtualDevice);
      expect(LoopbackKind.fromCode(99), LoopbackKind.none);
    });
  });

  group('LoopbackInfo.none', () {
    test('is unavailable and not auto-routable', () {
      const info = LoopbackInfo.none();
      expect(info.available, isFalse);
      expect(info.kind, LoopbackKind.none);
      expect(info.deviceName, '');
      expect(info.isAutoRoutable, isFalse);
    });
  });

  group('LoopbackInfo.fromNative', () {
    test('projects an available virtual loopback with its device name', () {
      final ptr = calloc<le_loopback_info>();
      try {
        ptr.ref
          ..available = 1
          ..kind = 3;
        _writeName(ptr, 'BlackHole 2ch');

        final info = LoopbackInfo.fromNative(ptr);
        expect(info.available, isTrue);
        expect(info.kind, LoopbackKind.virtualDevice);
        expect(info.deviceName, 'BlackHole 2ch');
        expect(info.isAutoRoutable, isTrue);
      } finally {
        calloc.free(ptr);
      }
    });

    test('an unavailable result has an empty device name', () {
      final ptr = calloc<le_loopback_info>();
      try {
        ptr.ref.available = 0;
        final info = LoopbackInfo.fromNative(ptr);
        expect(info.available, isFalse);
        expect(info.deviceName, '');
        expect(info.isAutoRoutable, isFalse);
      } finally {
        calloc.free(ptr);
      }
    });

    test('WASAPI loopback is available but not auto-routable', () {
      final ptr = calloc<le_loopback_info>();
      try {
        ptr.ref
          ..available = 1
          ..kind = 1;
        // No device name written (built-in WASAPI path).
        final info = LoopbackInfo.fromNative(ptr);
        expect(info.kind, LoopbackKind.wasapi);
        expect(info.isAutoRoutable, isFalse);
      } finally {
        calloc.free(ptr);
      }
    });
  });
}
