part of 'audio_setup_cubit.dart';

/// A categorized audio-setup failure surfaced in the wizard error banner.
enum AudioSetupError {
  /// The engine failed to open or reopen the device.
  openDeviceFailed,

  /// The engine failed to start audio.
  startAudioFailed,
}

/// Whether the audio device is currently open.
enum AudioSetupStatus {
  /// The engine is stopped; the device is closed.
  stopped,

  /// The engine is running; the device is open.
  running,

  /// The engine failed to start.
  error,
}

/// The most recent pinned-device connectivity transition, used to drive a
/// transient connect/disconnect banner. Derived in the cubit by diffing
/// `EngineStatus.devicePresent`; not a separate stream.
enum DeviceConnectivity {
  /// No transition to report.
  none,

  /// The pinned device just went absent (1→0).
  lost,

  /// The pinned device just came back (0→1).
  restored,
}

/// State for the audio setup feature: the user's requested device options plus
/// the live engine status projected from the repository.
class AudioSetupState extends Equatable {
  /// Creates an [AudioSetupState].
  const AudioSetupState({
    this.sampleRate = 48000,
    this.bufferFrames = 128,
    this.monitorInput = true,
    this.exclusive = false,
    this.maxLoopMinutes = 0,
    this.status = AudioSetupStatus.stopped,
    this.engineStatus = const EngineStatus(),
    this.loopback = const LoopbackInfo.none(),
    this.devices = const [],
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
    this.backend = AudioBackend.wasapi,
    this.asioDriver = '',
    this.asioDrivers = const [],
    this.deviceConnectivity = DeviceConnectivity.none,
    this.connectivityDeviceName = '',
    this.error,
    this.errorDetail,
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

  /// Whether captured input is monitored to the output.
  final bool monitorInput;

  /// Whether OS-exclusive device access is requested (full control on Windows:
  /// bypasses the mixer, native format). This is the user's *intent*; the
  /// engine falls back to shared if exclusive is refused, and the negotiated
  /// reality is read from [engineStatus]'s `exclusiveActive`. No effect off
  /// Windows (the toggle is not shown there).
  final bool exclusive;

  /// Maximum loop length per track, in whole minutes. `0` defers to the engine
  /// default. Applied on the next start (buffers are allocated at start).
  final int maxLoopMinutes;

  /// High-level lifecycle status.
  final AudioSetupStatus status;

  /// Live engine/device status from the repository.
  final EngineStatus engineStatus;

  /// The detected cable-free loopback path (if any) used to auto-measure
  /// latency without a physical cable.
  final LoopbackInfo loopback;

  /// The host's enumerated audio devices (playback + capture) for the pickers.
  final List<AudioDevice> devices;

  /// Selected playback device id, or empty for the system default.
  final String playbackDeviceId;

  /// Selected capture device id, or empty for the system default.
  final String captureDeviceId;

  /// The requested device backend (intent). Defaults to [AudioBackend.wasapi];
  /// [AudioBackend.asio] is selectable only on Windows with drivers present.
  /// The negotiated reality is read from [engineStatus]'s `activeBackend`.
  final AudioBackend backend;

  /// The selected ASIO driver id, or empty when none is chosen. Meaningful only
  /// when [backend] is [AudioBackend.asio].
  final String asioDriver;

  /// The installed ASIO drivers (one duplex [AudioDevice] each) for the driver
  /// picker. Empty off Windows / on the default build.
  final List<AudioDevice> asioDrivers;

  /// The most recent pinned-device connectivity transition (drives the banner).
  final DeviceConnectivity deviceConnectivity;

  /// Name of the device involved in the latest [deviceConnectivity] transition.
  final String connectivityDeviceName;

  /// The categorized error when [status] is [AudioSetupStatus.error].
  final AudioSetupError? error;

  /// Engine error detail (e.g. result name) for [error].
  final String? errorDetail;

  /// Playback (output) devices from [devices].
  List<AudioDevice> get playbackDevices =>
      devices.where((d) => !d.isInput).toList();

  /// Capture (input) devices from [devices].
  List<AudioDevice> get captureDevices =>
      devices.where((d) => d.isInput).toList();

  /// Whether the ASIO backend is the requested intent.
  bool get isAsio => backend == AudioBackend.asio;

  /// Selectable sample rates.
  static const sampleRates = [44100, 48000, 96000];

  /// Selectable buffer sizes.
  static const bufferSizes = [64, 128, 256, 512];

  /// Selectable max-loop-length options, in minutes. `0` is the engine default.
  static const maxLoopMinuteOptions = [0, 2, 5, 10];

  /// Returns a copy with the given fields replaced.
  AudioSetupState copyWith({
    int? sampleRate,
    int? bufferFrames,
    bool? monitorInput,
    bool? exclusive,
    int? maxLoopMinutes,
    AudioSetupStatus? status,
    EngineStatus? engineStatus,
    LoopbackInfo? loopback,
    List<AudioDevice>? devices,
    String? playbackDeviceId,
    String? captureDeviceId,
    AudioBackend? backend,
    String? asioDriver,
    List<AudioDevice>? asioDrivers,
    DeviceConnectivity? deviceConnectivity,
    String? connectivityDeviceName,
    AudioSetupError? error,
    String? errorDetail,
  }) {
    return AudioSetupState(
      sampleRate: sampleRate ?? this.sampleRate,
      bufferFrames: bufferFrames ?? this.bufferFrames,
      monitorInput: monitorInput ?? this.monitorInput,
      exclusive: exclusive ?? this.exclusive,
      maxLoopMinutes: maxLoopMinutes ?? this.maxLoopMinutes,
      status: status ?? this.status,
      engineStatus: engineStatus ?? this.engineStatus,
      loopback: loopback ?? this.loopback,
      devices: devices ?? this.devices,
      playbackDeviceId: playbackDeviceId ?? this.playbackDeviceId,
      captureDeviceId: captureDeviceId ?? this.captureDeviceId,
      backend: backend ?? this.backend,
      asioDriver: asioDriver ?? this.asioDriver,
      asioDrivers: asioDrivers ?? this.asioDrivers,
      deviceConnectivity: deviceConnectivity ?? this.deviceConnectivity,
      connectivityDeviceName:
          connectivityDeviceName ?? this.connectivityDeviceName,
      error: error ?? this.error,
      errorDetail: errorDetail ?? this.errorDetail,
    );
  }

  @override
  List<Object?> get props => [
    sampleRate,
    bufferFrames,
    monitorInput,
    exclusive,
    maxLoopMinutes,
    status,
    engineStatus,
    loopback,
    devices,
    playbackDeviceId,
    captureDeviceId,
    backend,
    asioDriver,
    asioDrivers,
    deviceConnectivity,
    connectivityDeviceName,
    error,
    errorDetail,
  ];
}
