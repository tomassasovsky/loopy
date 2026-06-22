import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart' as engine;

/// Which device backend the engine should open. Domain mirror of the engine's
/// `AudioBackend`; on Windows the engine forces [asio], [miniaudio] is the
/// cross-platform path used on macOS and Linux.
enum AudioBackend {
  /// The platform's default miniaudio backend.
  miniaudio,

  /// Windows ASIO.
  asio,
}

/// Phase of the round-trip latency measurement harness. Domain mirror of the
/// engine's `LatencyState`.
enum LatencyState {
  /// No measurement has been requested.
  idle,

  /// An impulse has been emitted and the engine is waiting for it to return.
  measuring,

  /// A measurement completed; the measured latency is valid.
  done,

  /// No loopback signal was detected within the measurement window.
  timeout,
}

/// Classification of a cable-free loopback path used to auto-measure latency.
/// Domain mirror of the engine's `LoopbackKind`.
enum LoopbackKind {
  /// No loopback path detected.
  none,

  /// The device backend's built-in output loopback (detected, not auto-routed).
  backendLoopback,

  /// PulseAudio "Monitor of …" source (Linux).
  monitor,

  /// A named virtual audio driver (BlackHole, VB-Cable, …).
  virtualDevice,
}

/// A hardware audio device discovered by the repository. Domain mirror of the
/// engine's `AudioDevice`.
class AudioDevice extends Equatable {
  /// Creates an [AudioDevice].
  const AudioDevice({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.isInput,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.bufferSizes = const [],
    this.sampleRates = const [],
  });

  /// The backend-specific device id, suitable for pinning via
  /// [EngineConfig.playbackDeviceId] / [EngineConfig.captureDeviceId].
  final String id;

  /// The human-readable device label.
  final String name;

  /// Whether this is the system default device for its direction.
  final bool isDefault;

  /// Whether this is a capture (input) device; `false` for a playback device.
  final bool isInput;

  /// The device's hardware capture channel count, or `0` when unknown.
  final int inputChannels;

  /// The device's hardware playback channel count, or `0` when unknown.
  final int outputChannels;

  /// The driver's selectable buffer sizes (ASIO drivers only; empty otherwise).
  final List<int> bufferSizes;

  /// The driver's supported sample rates in Hz (ASIO drivers only; empty
  /// otherwise).
  final List<int> sampleRates;

  @override
  List<Object?> get props => [
    id,
    name,
    isDefault,
    isInput,
    inputChannels,
    outputChannels,
    bufferSizes,
    sampleRates,
  ];
}

/// Requested audio device configuration. Domain mirror of the engine's
/// `EngineConfig`; any field left at `0`/empty defers to the device default.
class EngineConfig extends Equatable {
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
    this.backend = AudioBackend.miniaudio,
    this.asioDriver = '',
  });

  /// Requested sample rate in Hz, or `0` for the device default.
  final int sampleRate;

  /// Requested period (buffer) size in frames, or `0` for the device default.
  final int bufferFrames;

  /// Requested hardware capture channel count, or `0` for the device default.
  final int inputChannels;

  /// Requested hardware playback channel count, or `0` for the device default.
  final int outputChannels;

  /// Per-track loop buffer cap in frames, or `0` for the engine default.
  final int maxLoopFrames;

  /// Whether the engine should capture from a detected loopback device.
  final bool useLoopbackCapture;

  /// The id of the playback device to open, or empty for the system default.
  final String playbackDeviceId;

  /// The id of the capture device to open, or empty for the system default.
  final String captureDeviceId;

  /// Which device backend to open.
  final AudioBackend backend;

  /// Selected ASIO driver name, used only when [backend] is ASIO.
  final String asioDriver;

  @override
  List<Object?> get props => [
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    maxLoopFrames,
    useLoopbackCapture,
    playbackDeviceId,
    captureDeviceId,
    backend,
    asioDriver,
  ];
}

/// The result of loopback detection. Domain mirror of the engine's
/// `LoopbackInfo`.
class LoopbackInfo extends Equatable {
  /// Creates a [LoopbackInfo].
  const LoopbackInfo({
    required this.available,
    required this.kind,
    required this.deviceName,
  });

  /// A result indicating no loopback path is available.
  const LoopbackInfo.none()
    : available = false,
      kind = LoopbackKind.none,
      deviceName = '';

  /// Whether a cable-free loopback path was found.
  final bool available;

  /// The kind of loopback detected.
  final LoopbackKind kind;

  /// The capture device to open for an auto-measurement, or empty when the
  /// loopback is the backend's built-in path that is not auto-routed.
  final String deviceName;

  /// Whether the engine can auto-route capture from this loopback.
  bool get isAutoRoutable => available && deviceName.isNotEmpty;

  @override
  List<Object?> get props => [available, kind, deviceName];
}

// --- Boundary mappers (package-internal; not exported from the barrel). ---

/// Maps an engine `AudioBackend` to its domain mirror.
AudioBackend audioBackendFromEngine(engine.AudioBackend backend) =>
    switch (backend) {
      engine.AudioBackend.miniaudio => AudioBackend.miniaudio,
      engine.AudioBackend.asio => AudioBackend.asio,
    };

/// Maps a domain [AudioBackend] to the engine enum at the boundary.
engine.AudioBackend audioBackendToEngine(AudioBackend backend) =>
    switch (backend) {
      AudioBackend.miniaudio => engine.AudioBackend.miniaudio,
      AudioBackend.asio => engine.AudioBackend.asio,
    };

/// Maps an engine `LatencyState` to its domain mirror.
LatencyState latencyStateFromEngine(engine.LatencyState state) =>
    switch (state) {
      engine.LatencyState.idle => LatencyState.idle,
      engine.LatencyState.measuring => LatencyState.measuring,
      engine.LatencyState.done => LatencyState.done,
      engine.LatencyState.timeout => LatencyState.timeout,
    };

/// Maps an engine `LoopbackKind` to its domain mirror.
LoopbackKind loopbackKindFromEngine(engine.LoopbackKind kind) => switch (kind) {
  engine.LoopbackKind.none => LoopbackKind.none,
  engine.LoopbackKind.backendLoopback => LoopbackKind.backendLoopback,
  engine.LoopbackKind.monitor => LoopbackKind.monitor,
  engine.LoopbackKind.virtualDevice => LoopbackKind.virtualDevice,
};

/// Maps an engine `AudioDevice` to its domain mirror.
AudioDevice audioDeviceFromEngine(engine.AudioDevice device) => AudioDevice(
  id: device.id,
  name: device.name,
  isDefault: device.isDefault,
  isInput: device.isInput,
  inputChannels: device.inputChannels,
  outputChannels: device.outputChannels,
  bufferSizes: device.bufferSizes,
  sampleRates: device.sampleRates,
);

/// Maps an engine `LoopbackInfo` to its domain mirror.
LoopbackInfo loopbackInfoFromEngine(engine.LoopbackInfo info) => LoopbackInfo(
  available: info.available,
  kind: loopbackKindFromEngine(info.kind),
  deviceName: info.deviceName,
);

/// Maps a domain [EngineConfig] to the engine type at the repository boundary.
engine.EngineConfig engineConfigToEngine(EngineConfig config) =>
    engine.EngineConfig(
      sampleRate: config.sampleRate,
      bufferFrames: config.bufferFrames,
      inputChannels: config.inputChannels,
      outputChannels: config.outputChannels,
      maxLoopFrames: config.maxLoopFrames,
      useLoopbackCapture: config.useLoopbackCapture,
      playbackDeviceId: config.playbackDeviceId,
      captureDeviceId: config.captureDeviceId,
      backend: audioBackendToEngine(config.backend),
      asioDriver: config.asioDriver,
    );
