part of 'audio_setup_cubit.dart';

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
    this.mergeToMono = true,
    this.status = AudioSetupStatus.stopped,
    this.engineStatus = const EngineStatus(),
    this.loopback = const LoopbackInfo.none(),
    this.devices = const [],
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
    this.deviceConnectivity = DeviceConnectivity.none,
    this.connectivityDeviceName = '',
    this.errorMessage,
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

  /// Whether captured input is monitored to the output.
  final bool monitorInput;

  /// Whether input channels are averaged to mono and fed to both outputs.
  final bool mergeToMono;

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

  /// The most recent pinned-device connectivity transition (drives the banner).
  final DeviceConnectivity deviceConnectivity;

  /// Name of the device involved in the latest [deviceConnectivity] transition.
  final String connectivityDeviceName;

  /// A human-readable error when [status] is [AudioSetupStatus.error].
  final String? errorMessage;

  /// Playback (output) devices from [devices].
  List<AudioDevice> get playbackDevices =>
      devices.where((d) => !d.isInput).toList();

  /// Capture (input) devices from [devices].
  List<AudioDevice> get captureDevices =>
      devices.where((d) => d.isInput).toList();

  /// Selectable sample rates.
  static const sampleRates = [44100, 48000, 96000];

  /// Selectable buffer sizes.
  static const bufferSizes = [64, 128, 256, 512];

  /// Returns a copy with the given fields replaced.
  AudioSetupState copyWith({
    int? sampleRate,
    int? bufferFrames,
    bool? monitorInput,
    bool? mergeToMono,
    AudioSetupStatus? status,
    EngineStatus? engineStatus,
    LoopbackInfo? loopback,
    List<AudioDevice>? devices,
    String? playbackDeviceId,
    String? captureDeviceId,
    DeviceConnectivity? deviceConnectivity,
    String? connectivityDeviceName,
    String? errorMessage,
  }) {
    return AudioSetupState(
      sampleRate: sampleRate ?? this.sampleRate,
      bufferFrames: bufferFrames ?? this.bufferFrames,
      monitorInput: monitorInput ?? this.monitorInput,
      mergeToMono: mergeToMono ?? this.mergeToMono,
      status: status ?? this.status,
      engineStatus: engineStatus ?? this.engineStatus,
      loopback: loopback ?? this.loopback,
      devices: devices ?? this.devices,
      playbackDeviceId: playbackDeviceId ?? this.playbackDeviceId,
      captureDeviceId: captureDeviceId ?? this.captureDeviceId,
      deviceConnectivity: deviceConnectivity ?? this.deviceConnectivity,
      connectivityDeviceName:
          connectivityDeviceName ?? this.connectivityDeviceName,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [
    sampleRate,
    bufferFrames,
    monitorInput,
    mergeToMono,
    status,
    engineStatus,
    loopback,
    devices,
    playbackDeviceId,
    captureDeviceId,
    deviceConnectivity,
    connectivityDeviceName,
    errorMessage,
  ];
}
