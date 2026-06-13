import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:loopy_engine/src/ffi_strings.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';

void main() {
  group('EngineConfig defaults', () {
    test('all fields default to device-default sentinels', () {
      const config = EngineConfig();
      expect(config.sampleRate, 0);
      expect(config.bufferFrames, 0);
      expect(config.inputChannels, 0);
      expect(config.outputChannels, 0);
      expect(config.playbackDeviceId, '');
      expect(config.captureDeviceId, '');
      expect(config.exclusive, isFalse);
      expect(config.backend, AudioBackend.wasapi);
      expect(config.asioDriver, '');
    });
  });

  group('AudioBackend', () {
    test('round-trips through the native integer', () {
      for (final backend in AudioBackend.values) {
        expect(AudioBackend.fromNative(backend.toNative()), backend);
      }
    });

    test('maps the native enum values explicitly', () {
      expect(AudioBackend.wasapi.toNative(), 0);
      expect(AudioBackend.asio.toNative(), 1);
      expect(AudioBackend.fromNative(0), AudioBackend.wasapi);
      expect(AudioBackend.fromNative(1), AudioBackend.asio);
    });

    test('unknown native values fall back to wasapi', () {
      expect(AudioBackend.fromNative(-1), AudioBackend.wasapi);
      expect(AudioBackend.fromNative(99), AudioBackend.wasapi);
    });
  });

  group('EngineConfig.writeTo', () {
    test('writes every field into the native struct', () {
      const config = EngineConfig(
        sampleRate: 48000,
        bufferFrames: 64,
        inputChannels: 2,
        outputChannels: 4,
        maxLoopFrames: 480000,
        useLoopbackCapture: true,
        playbackDeviceId: 'out-device-1',
        captureDeviceId: 'in-device-2',
        exclusive: true,
        backend: AudioBackend.asio,
        asioDriver: 'ASIO4ALL v2',
      );
      final ptr = calloc<le_config>();
      try {
        config.writeTo(ptr);
        expect(ptr.ref.sample_rate, 48000);
        expect(ptr.ref.buffer_frames, 64);
        expect(ptr.ref.input_channels, 2);
        expect(ptr.ref.output_channels, 4);
        expect(ptr.ref.max_loop_frames, 480000);
        expect(ptr.ref.use_loopback_capture, 1);
        expect(ptr.ref.exclusive, 1);
        expect(ptr.ref.backend, 1); // AudioBackend.asio
        expect(readNativeString(ptr.ref.playback_device_id), 'out-device-1');
        expect(readNativeString(ptr.ref.capture_device_id), 'in-device-2');
        expect(readNativeString(ptr.ref.asio_driver), 'ASIO4ALL v2');
      } finally {
        calloc.free(ptr);
      }
    });

    test('defaults write the WASAPI backend and an empty asio driver', () {
      const config = EngineConfig();
      final ptr = calloc<le_config>();
      try {
        config.writeTo(ptr);
        expect(ptr.ref.backend, 0); // AudioBackend.wasapi
        expect(readNativeString(ptr.ref.asio_driver), '');
      } finally {
        calloc.free(ptr);
      }
    });

    test('encodes exclusive false as 0', () {
      const config = EngineConfig();
      final ptr = calloc<le_config>();
      try {
        config.writeTo(ptr);
        expect(ptr.ref.exclusive, 0);
      } finally {
        calloc.free(ptr);
      }
    });

    test('empty device ids write a NUL-terminated empty string', () {
      const config = EngineConfig();
      final ptr = calloc<le_config>();
      try {
        config.writeTo(ptr);
        expect(readNativeString(ptr.ref.playback_device_id), '');
        expect(readNativeString(ptr.ref.capture_device_id), '');
      } finally {
        calloc.free(ptr);
      }
    });

    test('a device id longer than the buffer is truncated and terminated', () {
      final config = EngineConfig(playbackDeviceId: 'x' * 400);
      final ptr = calloc<le_config>();
      try {
        config.writeTo(ptr);
        final written = readNativeString(ptr.ref.playback_device_id);
        expect(written.length, 255); // 256-byte buffer, 1 byte for the NUL
        expect(written, 'x' * 255);
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

    test('differing device ids break equality', () {
      const a = EngineConfig(playbackDeviceId: 'a');
      const b = EngineConfig(playbackDeviceId: 'b');
      expect(a, isNot(equals(b)));
      const c = EngineConfig(captureDeviceId: 'a');
      const d = EngineConfig();
      expect(c, isNot(equals(d)));
    });

    test('differing exclusive breaks equality', () {
      const a = EngineConfig(exclusive: true);
      const b = EngineConfig();
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });

    test('differing backend or asio driver breaks equality', () {
      const a = EngineConfig(backend: AudioBackend.asio);
      const b = EngineConfig();
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
      const c = EngineConfig(asioDriver: 'ASIO4ALL v2');
      const d = EngineConfig();
      expect(c, isNot(equals(d)));
      expect(c.hashCode, isNot(equals(d.hashCode)));
    });

    test('toString surfaces key fields', () {
      const config = EngineConfig(
        sampleRate: 48000,
        backend: AudioBackend.asio,
      );
      expect(config.toString(), contains('sampleRate: 48000'));
      expect(config.toString(), contains('backend: asio'));
    });
  });
}
