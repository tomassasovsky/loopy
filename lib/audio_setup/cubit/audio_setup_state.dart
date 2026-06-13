part of 'audio_setup_cubit.dart';

/// A categorized audio-setup failure surfaced in the audio-settings error
/// banner.
enum AudioSetupError {
  /// The engine failed to open or reopen the device.
  openDeviceFailed,
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
    this.cachedAsioDrivers = const [],
    this.asioOnly = false,
    this.deviceConnectivity = DeviceConnectivity.none,
    this.connectivityDeviceName = '',
    this.error,
    this.errorDetail,
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

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

  /// The ASIO drivers enumerated once at process start, cached so the picker
  /// stays populated even while ASIO holds the device (re-probing live would
  /// tear the stream down — R1). [asioDrivers] falls back to this while live.
  final List<AudioDevice> cachedAsioDrivers;

  /// Whether this platform runs ASIO exclusively (Windows): the backend is
  /// hardwired to ASIO, there is no WASAPI selector or device picker, and the
  /// no-driver / ASIO4ALL affordances apply. `false` on macOS/Linux.
  final bool asioOnly;

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

  /// The currently selected ASIO driver from [asioDrivers], or `null` when none
  /// matches [asioDriver].
  AudioDevice? get selectedAsioDriver {
    for (final driver in asioDrivers) {
      if (driver.id == asioDriver) return driver;
    }
    return null;
  }

  /// The buffer-size options to offer the user: under ASIO, the selected
  /// driver's real set (probed from the driver — e.g. a Focusrite locked to its
  /// Focusrite Control setting); otherwise the generic [bufferSizes] list.
  List<int> get bufferChoices {
    final driver = selectedAsioDriver;
    if (isAsio && driver != null && driver.bufferSizes.isNotEmpty) {
      return driver.bufferSizes;
    }
    return bufferSizes;
  }

  /// The sample-rate options to offer: the selected ASIO driver's supported
  /// rates under ASIO, otherwise the generic [sampleRates] list.
  List<int> get sampleRateChoices {
    final driver = selectedAsioDriver;
    if (isAsio && driver != null && driver.sampleRates.isNotEmpty) {
      return driver.sampleRates;
    }
    return sampleRates;
  }

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
    List<AudioDevice>? cachedAsioDrivers,
    bool? asioOnly,
    DeviceConnectivity? deviceConnectivity,
    String? connectivityDeviceName,
    AudioSetupError? error,
    String? errorDetail,
    bool clearError = false,
  }) {
    return AudioSetupState(
      sampleRate: sampleRate ?? this.sampleRate,
      bufferFrames: bufferFrames ?? this.bufferFrames,
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
      cachedAsioDrivers: cachedAsioDrivers ?? this.cachedAsioDrivers,
      asioOnly: asioOnly ?? this.asioOnly,
      deviceConnectivity: deviceConnectivity ?? this.deviceConnectivity,
      connectivityDeviceName:
          connectivityDeviceName ?? this.connectivityDeviceName,
      // [clearError] resets the error on a successful (re)start, since nullable
      // fields cannot otherwise be cleared through `?? this`.
      error: clearError ? null : (error ?? this.error),
      errorDetail: clearError ? null : (errorDetail ?? this.errorDetail),
    );
  }

  @override
  List<Object?> get props => [
    sampleRate,
    bufferFrames,
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
    cachedAsioDrivers,
    asioOnly,
    deviceConnectivity,
    connectivityDeviceName,
    error,
    errorDetail,
  ];
}
