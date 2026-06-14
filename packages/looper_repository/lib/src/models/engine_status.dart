import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// Device + engine health, projected from the engine snapshot.
class EngineStatus extends Equatable {
  /// Creates an [EngineStatus].
  const EngineStatus({
    this.deviceName = '',
    this.sampleRate = 0,
    this.bufferFrames = 0,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.latencyState = LatencyState.idle,
    this.measuredLatencyMs = -1,
    this.xrunCount = 0,
    this.isConnected = false,
    this.devicePresent = false,
    this.excludedInputMask = 0,
    this.recordOffsetFrames = 0,
    this.fxAddedLatencyFrames = 0,
    this.activeBackend = AudioBackend.miniaudio,
  });

  /// Active device name, or empty when stopped.
  final String deviceName;

  /// Negotiated sample rate in Hz.
  final int sampleRate;

  /// Negotiated buffer (period) size in frames.
  final int bufferFrames;

  /// Negotiated hardware capture channel count.
  final int inputChannels;

  /// Negotiated hardware playback channel count.
  final int outputChannels;

  /// Phase of the latency harness.
  final LatencyState latencyState;

  /// Measured round-trip latency in ms, valid when [latencyState] is
  /// [LatencyState.done].
  final double measuredLatencyMs;

  /// Device xruns since the device started (reserved; currently `0`).
  final int xrunCount;

  /// Whether the audio device is open and running.
  final bool isConnected;

  /// Whether the pinned (or default) device is currently present.
  ///
  /// Distinct from [isConnected]: a pinned device can be lost (unplugged) while
  /// the engine object still reports running until it is restarted. The
  /// disconnect signal the reconnect supervisor and the banner are driven from.
  final bool devicePresent;

  /// Bitmask of input channels excluded as loopback (never recorded, monitored,
  /// or routable). `0` when nothing is excluded (always so off macOS).
  final int excludedInputMask;

  /// Record-offset latency compensation in frames (auto-set by a measurement).
  final int recordOffsetFrames;

  /// Added latency (frames) of the highest-latency effect engaged in any
  /// audible or monitored lane chain — the maximum across active effects. Today
  /// only the formant-preserving octaver contributes; `0` when no octaver is
  /// engaged. Purely informational (see [fxAddedLatencyMs]); it never feeds
  /// [recordOffsetFrames] or any compensation.
  final int fxAddedLatencyFrames;

  /// [fxAddedLatencyFrames] expressed in milliseconds at the current
  /// [sampleRate]; `0` when no effect adds latency or the rate is unknown.
  double get fxAddedLatencyMs =>
      sampleRate > 0 ? fxAddedLatencyFrames * 1000 / sampleRate : 0;

  /// The device backend actually running (negotiated) — the reality behind the
  /// requested [EngineConfig.backend] intent. On Windows this is always
  /// [AudioBackend.asio]; on macOS/Linux it is [AudioBackend.miniaudio].
  final AudioBackend activeBackend;

  /// Whether a latency measurement has completed.
  bool get hasMeasuredLatency => latencyState == LatencyState.done;

  @override
  List<Object?> get props => [
    deviceName,
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    latencyState,
    measuredLatencyMs,
    xrunCount,
    isConnected,
    devicePresent,
    excludedInputMask,
    recordOffsetFrames,
    fxAddedLatencyFrames,
    activeBackend,
  ];
}
