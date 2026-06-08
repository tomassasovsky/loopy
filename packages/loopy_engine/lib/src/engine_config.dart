import 'dart:ffi';

import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:meta/meta.dart';

/// Requested audio device configuration passed to `AudioEngine.start`.
///
/// Any field left at `0` (or `false` for [passthrough]) defers to the device
/// default. This is the pure-Dart counterpart of the native `le_config` struct.
@immutable
class EngineConfig {
  /// Creates an [EngineConfig].
  const EngineConfig({
    this.sampleRate = 0,
    this.bufferFrames = 0,
    this.channels = 0,
    this.passthrough = false,
    this.maxLoopFrames = 0,
    this.mergeToMono = false,
    this.useLoopbackCapture = false,
  });

  /// Requested sample rate in Hz, or `0` for the device default.
  final int sampleRate;

  /// Requested period (buffer) size in frames, or `0` for the device default.
  ///
  /// Smaller values reduce latency at the cost of xrun risk.
  final int bufferFrames;

  /// Requested channel count, or `0` for the device default. Clamped to a
  /// maximum of two by the engine.
  final int channels;

  /// Whether captured input should be copied straight to the output.
  final bool passthrough;

  /// Per-track loop buffer cap in frames, or `0` for the engine default
  /// (about two minutes at the device sample rate).
  final int maxLoopFrames;

  /// Whether captured input channels are averaged to mono and fed to every
  /// output channel. Useful for a mono source (e.g. a single mic on input 1)
  /// so it is heard on both sides instead of one.
  final bool mergeToMono;

  /// Whether the engine should capture from a detected loopback device (so
  /// latency can be measured without a physical cable). No effect when no
  /// loopback is detected.
  final bool useLoopbackCapture;

  /// Writes this configuration into a native [le_config] struct in [ptr].
  void writeTo(Pointer<le_config> ptr) {
    ptr.ref
      ..sample_rate = sampleRate
      ..buffer_frames = bufferFrames
      ..channels = channels
      ..passthrough = passthrough ? 1 : 0
      ..max_loop_frames = maxLoopFrames
      ..merge_to_mono = mergeToMono ? 1 : 0
      ..use_loopback_capture = useLoopbackCapture ? 1 : 0;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineConfig &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          channels == other.channels &&
          passthrough == other.passthrough &&
          maxLoopFrames == other.maxLoopFrames &&
          mergeToMono == other.mergeToMono &&
          useLoopbackCapture == other.useLoopbackCapture;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    bufferFrames,
    channels,
    passthrough,
    maxLoopFrames,
    mergeToMono,
    useLoopbackCapture,
  );

  @override
  String toString() =>
      'EngineConfig(sampleRate: $sampleRate, '
      'bufferFrames: $bufferFrames, channels: $channels, '
      'passthrough: $passthrough, maxLoopFrames: $maxLoopFrames, '
      'mergeToMono: $mergeToMono, useLoopbackCapture: $useLoopbackCapture)';
}
