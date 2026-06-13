import 'dart:ffi';

import 'package:loopy_engine/src/ffi_strings.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:meta/meta.dart';

/// Which device backend the engine should open.
///
/// Mirrors the native `le_audio_backend` enum. [asio] is opt-in and only
/// available in a `LOOPY_ENABLE_ASIO` build (the real backend lands in Part 2);
/// today every choice resolves to the default miniaudio path.
enum AudioBackend {
  /// The default miniaudio backend for the platform (WASAPI on Windows, Core
  /// Audio on macOS, the Linux preference list).
  wasapi,

  /// Opt-in Windows ASIO. Accepted but treated as [wasapi] until Part 2.
  asio;

  /// The native `le_audio_backend` integer for this backend.
  int toNative() => switch (this) {
    AudioBackend.wasapi => 0,
    AudioBackend.asio => 1,
  };

  /// Maps a native `le_audio_backend` integer to an [AudioBackend]; unknown
  /// values fall back to [wasapi].
  static AudioBackend fromNative(int value) => switch (value) {
    1 => AudioBackend.asio,
    _ => AudioBackend.wasapi,
  };
}

/// Requested audio device configuration passed to `AudioEngine.start`.
///
/// Any field left at `0` defers to the device default. This is the pure-Dart
/// counterpart of the native `le_config` struct.
@immutable
class EngineConfig {
  /// Creates an [EngineConfig].
  const EngineConfig({
    this.sampleRate = 0,
    this.bufferFrames = 0,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.maxLoopFrames = 0,
    this.useLoopbackCapture = false,
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
    this.exclusive = false,
    this.backend = AudioBackend.wasapi,
    this.asioDriver = '',
  });

  /// Requested sample rate in Hz, or `0` for the device default.
  final int sampleRate;

  /// Requested period (buffer) size in frames, or `0` for the device default.
  ///
  /// Smaller values reduce latency at the cost of xrun risk.
  final int bufferFrames;

  /// Requested hardware capture channel count, or `0` for the device default.
  /// Clamped to the engine maximum.
  final int inputChannels;

  /// Requested hardware playback channel count, or `0` for the device default.
  /// Clamped to the engine maximum.
  final int outputChannels;

  /// Per-track loop buffer cap in frames, or `0` for the engine default
  /// (about two minutes at the device sample rate).
  final int maxLoopFrames;

  /// Whether the engine should capture from a detected loopback device (so
  /// latency can be measured without a physical cable). No effect when no
  /// loopback is detected.
  final bool useLoopbackCapture;

  /// The id of the playback device to open (an `AudioDevice.id` from
  /// `AudioEngine.enumerateDevices`), or the empty string for the system
  /// default (the unchanged behaviour).
  final String playbackDeviceId;

  /// The id of the capture device to open, or the empty string for the system
  /// default. Ignored when [useLoopbackCapture] resolves a loopback device.
  final String captureDeviceId;

  /// Whether to request OS-exclusive device access (WASAPI exclusive mode on
  /// Windows: bypasses the mixer, native format, no resampling). The engine
  /// falls back to shared mode automatically if exclusive is refused; the
  /// negotiated result is reported via `EngineSnapshot.exclusiveActive`. No
  /// effect on backends without an exclusive concept.
  final bool exclusive;

  /// Which device backend to open. Defaults to [AudioBackend.wasapi] (the
  /// platform's default miniaudio backend); [AudioBackend.asio] is opt-in and
  /// only honored in Part 2.
  final AudioBackend backend;

  /// Selected ASIO driver name, used only when [backend] is
  /// [AudioBackend.asio] (Part 2). Empty and ignored on the default path.
  final String asioDriver;

  /// Writes this configuration into a native [le_config] struct in [ptr].
  void writeTo(Pointer<le_config> ptr) {
    ptr.ref
      ..sample_rate = sampleRate
      ..buffer_frames = bufferFrames
      ..input_channels = inputChannels
      ..output_channels = outputChannels
      ..max_loop_frames = maxLoopFrames
      ..use_loopback_capture = useLoopbackCapture ? 1 : 0
      ..exclusive = exclusive ? 1 : 0
      ..backend = backend.toNative();
    writeNativeString(ptr.ref.playback_device_id, playbackDeviceId);
    writeNativeString(ptr.ref.capture_device_id, captureDeviceId);
    writeNativeString(ptr.ref.asio_driver, asioDriver);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineConfig &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          inputChannels == other.inputChannels &&
          outputChannels == other.outputChannels &&
          maxLoopFrames == other.maxLoopFrames &&
          useLoopbackCapture == other.useLoopbackCapture &&
          playbackDeviceId == other.playbackDeviceId &&
          captureDeviceId == other.captureDeviceId &&
          exclusive == other.exclusive &&
          backend == other.backend &&
          asioDriver == other.asioDriver;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    maxLoopFrames,
    useLoopbackCapture,
    playbackDeviceId,
    captureDeviceId,
    exclusive,
    backend,
    asioDriver,
  );

  @override
  String toString() =>
      'EngineConfig(sampleRate: $sampleRate, '
      'bufferFrames: $bufferFrames, inputChannels: $inputChannels, '
      'outputChannels: $outputChannels, '
      'maxLoopFrames: $maxLoopFrames, '
      'useLoopbackCapture: $useLoopbackCapture, '
      'playbackDeviceId: $playbackDeviceId, '
      'captureDeviceId: $captureDeviceId, '
      'exclusive: $exclusive, backend: ${backend.name}, '
      'asioDriver: $asioDriver)';
}
