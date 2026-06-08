import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:meta/meta.dart';

/// Phase of the loopback round-trip latency harness.
///
/// Mirrors the native `le_latency_state` enum.
enum LatencyState {
  /// No measurement has been requested.
  idle,

  /// An impulse has been emitted and the engine is waiting for it to return.
  measuring,

  /// A measurement completed; [EngineSnapshot.measuredLatencyMs] is valid.
  done,

  /// No loopback signal was detected within the measurement window.
  timeout;

  /// Maps a native `le_latency_state` integer to a [LatencyState].
  ///
  /// Unknown values fall back to [LatencyState.idle].
  static LatencyState fromCode(int code) => switch (code) {
    0 => LatencyState.idle,
    1 => LatencyState.measuring,
    2 => LatencyState.done,
    3 => LatencyState.timeout,
    _ => LatencyState.idle,
  };
}

/// An immutable, lock-free snapshot of the native audio engine's state.
///
/// Published by the engine's audio thread and read by Dart on a render-rate
/// timer. This is the pure-Dart projection of the native `le_snapshot` struct;
/// consumers never touch FFI memory directly.
@immutable
class EngineSnapshot {
  /// Creates an [EngineSnapshot] with explicit values.
  const EngineSnapshot({
    required this.isRunning,
    required this.sampleRate,
    required this.bufferFrames,
    required this.channels,
    required this.framesProcessed,
    required this.xrunCount,
    required this.inputRms,
    required this.inputPeak,
    required this.outputRms,
    required this.latencyState,
    required this.measuredLatencyMs,
  });

  /// The snapshot of an engine that has never started.
  const EngineSnapshot.initial()
    : isRunning = false,
      sampleRate = 0,
      bufferFrames = 0,
      channels = 0,
      framesProcessed = 0,
      xrunCount = 0,
      inputRms = 0,
      inputPeak = 0,
      outputRms = 0,
      latencyState = LatencyState.idle,
      measuredLatencyMs = -1;

  /// Projects a native `le_snapshot` struct into an [EngineSnapshot].
  factory EngineSnapshot.fromNative(le_snapshot native) => EngineSnapshot(
    isRunning: native.running != 0,
    sampleRate: native.sample_rate,
    bufferFrames: native.buffer_frames,
    channels: native.channels,
    framesProcessed: native.frames_processed,
    xrunCount: native.xrun_count,
    inputRms: native.input_rms,
    inputPeak: native.input_peak,
    outputRms: native.output_rms,
    latencyState: LatencyState.fromCode(native.latency_state),
    measuredLatencyMs: native.measured_latency_ms,
  );

  /// Whether the audio device is open and the callback is running.
  final bool isRunning;

  /// Negotiated device sample rate in Hz.
  final int sampleRate;

  /// Negotiated device period (buffer) size in frames.
  final int bufferFrames;

  /// Number of channels in the duplex stream.
  final int channels;

  /// Total frames processed by the audio callback since the device started.
  final int framesProcessed;

  /// Device xruns (dropouts) since the device started.
  ///
  /// Reserved: xrun detection is wired in Phase 2 and is currently always `0`.
  final int xrunCount;

  /// Input RMS level for the most recent block, in `0..1`.
  final double inputRms;

  /// Input peak level for the most recent block, in `0..1`.
  final double inputPeak;

  /// Output RMS level for the most recent block, in `0..1`.
  final double outputRms;

  /// Phase of the latency harness.
  final LatencyState latencyState;

  /// Measured round-trip latency in milliseconds, valid only when
  /// [latencyState] is [LatencyState.done]; otherwise `-1` or stale.
  final double measuredLatencyMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineSnapshot &&
          runtimeType == other.runtimeType &&
          isRunning == other.isRunning &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          channels == other.channels &&
          framesProcessed == other.framesProcessed &&
          xrunCount == other.xrunCount &&
          inputRms == other.inputRms &&
          inputPeak == other.inputPeak &&
          outputRms == other.outputRms &&
          latencyState == other.latencyState &&
          measuredLatencyMs == other.measuredLatencyMs;

  @override
  int get hashCode => Object.hash(
    isRunning,
    sampleRate,
    bufferFrames,
    channels,
    framesProcessed,
    xrunCount,
    inputRms,
    inputPeak,
    outputRms,
    latencyState,
    measuredLatencyMs,
  );

  @override
  String toString() =>
      'EngineSnapshot(running: $isRunning, '
      'sampleRate: $sampleRate, bufferFrames: $bufferFrames, '
      'channels: $channels, latency: $latencyState/$measuredLatencyMs ms)';
}
