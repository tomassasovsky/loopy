import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';

void main() {
  group('EngineConfig defaults', () {
    test('all fields default to device-default sentinels', () {
      const config = EngineConfig();
      expect(config.sampleRate, 0);
      expect(config.bufferFrames, 0);
      expect(config.channels, 0);
      expect(config.passthrough, isFalse);
    });
  });

  group('EngineConfig.writeTo', () {
    test('writes every field into the native struct', () {
      const config = EngineConfig(
        sampleRate: 48000,
        bufferFrames: 64,
        channels: 2,
        passthrough: true,
      );
      final ptr = calloc<le_config>();
      try {
        config.writeTo(ptr);
        expect(ptr.ref.sample_rate, 48000);
        expect(ptr.ref.buffer_frames, 64);
        expect(ptr.ref.channels, 2);
        expect(ptr.ref.passthrough, 1);
      } finally {
        calloc.free(ptr);
      }
    });

    test('encodes passthrough false as 0', () {
      const config = EngineConfig();
      final ptr = calloc<le_config>();
      try {
        config.writeTo(ptr);
        expect(ptr.ref.passthrough, 0);
      } finally {
        calloc.free(ptr);
      }
    });
  });

  group('value semantics', () {
    test('equal configs are equal and share a hashCode', () {
      const a = EngineConfig(sampleRate: 48000, bufferFrames: 128);
      const b = EngineConfig(sampleRate: 48000, bufferFrames: 128);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('differing configs are not equal', () {
      const a = EngineConfig(sampleRate: 48000);
      const b = EngineConfig(sampleRate: 44100);
      expect(a, isNot(equals(b)));
    });

    test('toString surfaces key fields', () {
      const config = EngineConfig(sampleRate: 48000, passthrough: true);
      expect(config.toString(), contains('sampleRate: 48000'));
      expect(config.toString(), contains('passthrough: true'));
    });
  });
}
