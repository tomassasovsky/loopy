import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// Device + engine health, projected from the engine snapshot.
class EngineStatus extends Equatable {
  /// Creates an [EngineStatus].
  const EngineStatus({
    this.deviceName = '',
    this.sampleRate = 0,
    this.bufferFrames = 0,
    this.channels = 0,
    this.latencyState = LatencyState.idle,
    this.measuredLatencyMs = -1,
    this.xrunCount = 0,
    this.isConnected = false,
  });

  /// Active device name, or empty when stopped.
  final String deviceName;

  /// Negotiated sample rate in Hz.
  final int sampleRate;

  /// Negotiated buffer (period) size in frames.
  final int bufferFrames;

  /// Channel count of the duplex stream.
  final int channels;

  /// Phase of the latency harness.
  final LatencyState latencyState;

  /// Measured round-trip latency in ms, valid when [latencyState] is
  /// [LatencyState.done].
  final double measuredLatencyMs;

  /// Device xruns since the device started (reserved; currently `0`).
  final int xrunCount;

  /// Whether the audio device is open and running.
  final bool isConnected;

  /// Whether a latency measurement has completed.
  bool get hasMeasuredLatency => latencyState == LatencyState.done;

  @override
  List<Object?> get props => [
    deviceName,
    sampleRate,
    bufferFrames,
    channels,
    latencyState,
    measuredLatencyMs,
    xrunCount,
    isConnected,
  ];
}
