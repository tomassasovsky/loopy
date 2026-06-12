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
    this.exclusiveActive = false,
    this.activeBackend = AudioBackend.wasapi,
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

  /// Whether the device is actually open in OS-exclusive mode. `false` for
  /// shared mode, including an exclusive request that fell back to shared. The
  /// negotiated reality behind the requested [EngineConfig.exclusive] intent.
  final bool exclusiveActive;

  /// The device backend actually running (negotiated). A requested-ASIO open
  /// that fell back to WASAPI reports [AudioBackend.wasapi] here — the reality
  /// behind the requested [EngineConfig.backend] intent.
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
    exclusiveActive,
    activeBackend,
  ];
}
