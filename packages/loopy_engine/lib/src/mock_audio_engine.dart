import 'dart:typed_data';

import 'package:loopy_engine/src/audio_device.dart';
import 'package:loopy_engine/src/audio_engine.dart';
import 'package:loopy_engine/src/engine_config.dart';
import 'package:loopy_engine/src/engine_snapshot.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:loopy_engine/src/loopback_info.dart';
import 'package:loopy_engine/src/track_effect.dart';

/// In-memory [AudioEngine] that simulates a multichannel interface for UI
/// development and manual testing without real hardware.
///
/// Reports [inputChannels] × [outputChannels] (default 18 × 20), enumerates a
/// single duplex device, and reflects lane / monitor routing in [snapshot].
class MockAudioEngine implements AudioEngine {
  /// Creates a [MockAudioEngine].
  MockAudioEngine({
    int inputChannels = defaultInputChannels,
    int outputChannels = defaultOutputChannels,
    String? deviceLabel,
  }) : inputChannels = inputChannels,
       outputChannels = outputChannels,
       deviceLabel =
           deviceLabel ??
           'Mock Interface (${inputChannels}i${outputChannels}o)';

  /// Default mock input channel count (Focusrite 18i20 class).
  static const int defaultInputChannels = 18;

  /// Default mock output channel count.
  static const int defaultOutputChannels = 20;

  /// Shared id for the mock playback and capture device entries.
  static const String deviceId = 'mock-interface';

  /// Negotiated input channel count while running.
  final int inputChannels;

  /// Negotiated output channel count while running.
  final int outputChannels;

  /// Human-readable label for [deviceName] and [enumerateDevices].
  final String deviceLabel;

  /// Sensible defaults for booting straight into the looper on the dev flavor.
  EngineConfig get defaultConfig => EngineConfig(
    sampleRate: 48000,
    bufferFrames: 128,
    inputChannels: inputChannels,
    outputChannels: outputChannels,
    playbackDeviceId: deviceId,
    captureDeviceId: deviceId,
  );

  bool _running = false;
  EngineConfig? _activeConfig;
  int _framesProcessed = 0;
  LatencyState _latencyState = LatencyState.idle;
  double _measuredLatencyMs = -1;
  int _recordOffsetFrames = 0;

  final List<_MockTrack> _tracks = List<_MockTrack>.generate(
    LE_MAX_TRACKS,
    (_) => _MockTrack(),
  );

  int get _negotiatedInputs {
    final requested = _activeConfig?.inputChannels ?? 0;
    return requested > 0 ? requested : inputChannels;
  }

  int get _negotiatedOutputs {
    final requested = _activeConfig?.outputChannels ?? 0;
    return requested > 0 ? requested : outputChannels;
  }

  @override
  String get version => 'mock-engine 0.0.0';

  @override
  String get deviceName => _running ? deviceLabel : '';

  @override
  EngineResult start(EngineConfig config) {
    if (_running) return EngineResult.alreadyRunning;
    _activeConfig = config;
    _running = true;
    _framesProcessed = 0;
    _latencyState = LatencyState.idle;
    _measuredLatencyMs = -1;
    return EngineResult.ok;
  }

  @override
  EngineResult stop() {
    if (!_running) return EngineResult.notRunning;
    _running = false;
    _activeConfig = null;
    return EngineResult.ok;
  }

  @override
  EngineSnapshot snapshot() {
    if (_running) {
      final buffer = _activeConfig?.bufferFrames ?? 128;
      _framesProcessed += buffer;
    }
    return EngineSnapshot(
      isRunning: _running,
      devicePresent: _running,
      sampleRate: _activeConfig?.sampleRate ?? 48000,
      bufferFrames: _activeConfig?.bufferFrames ?? 128,
      inputChannels: _running ? _negotiatedInputs : 0,
      outputChannels: _running ? _negotiatedOutputs : 0,
      framesProcessed: _framesProcessed,
      xrunCount: 0,
      inputRms: 0,
      inputPeak: 0,
      outputRms: 0,
      latencyState: _latencyState,
      measuredLatencyMs: _measuredLatencyMs,
      recordOffsetFrames: _recordOffsetFrames,
      // The mock echoes the requested backend as the negotiated one (ASIO
      // "succeeds"), so the requested-ASIO/reality-miniaudio fallback is NOT
      // exercised here — the widget test seeds that state directly.
      activeBackend: _running
          ? (_activeConfig?.backend ?? AudioBackend.miniaudio)
          : AudioBackend.miniaudio,
      tracks: [for (final track in _tracks) track.snapshot()],
    );
  }

  @override
  LoopbackInfo detectLoopback() => const LoopbackInfo.none();

  @override
  List<AudioDevice> enumerateDevices() => [
    AudioDevice(
      id: deviceId,
      name: deviceLabel,
      isDefault: true,
      isInput: false,
    ),
    AudioDevice(
      id: deviceId,
      name: deviceLabel,
      isDefault: true,
      isInput: true,
    ),
  ];

  @override
  List<AudioDevice> enumerateAsioDrivers() => const [
    // One deterministic fake duplex driver (18 in / 20 out), so UI development
    // and tests can drive the ASIO backend selector without real hardware. The
    // buffer/rate sets are a small fake of what a driver probe reports.
    AudioDevice(
      id: 'mock-asio',
      name: 'Mock ASIO Device',
      isDefault: false,
      isInput: false,
      inputChannels: 18,
      outputChannels: 20,
      bufferSizes: [128, 256, 512],
      sampleRates: [48000, 96000],
    ),
  ];

  @override
  EngineResult measureLatency() {
    if (!_running) return EngineResult.notRunning;
    _latencyState = LatencyState.done;
    _measuredLatencyMs = 5.3;
    return EngineResult.ok;
  }

  @override
  EngineResult record({int channel = 0}) => _requireRunning();

  @override
  EngineResult stopTrack({int channel = 0}) => _requireRunning();

  @override
  EngineResult play({int channel = 0}) => _requireRunning();

  @override
  EngineResult clear({int channel = 0}) => _requireRunning();

  @override
  EngineResult undo({int channel = 0}) => _requireRunning();

  @override
  EngineResult redo({int channel = 0}) => _requireRunning();

  @override
  EngineResult setLaneCount({required int channel, required int count}) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneCount = count.clamp(1, kMaxLanes);
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneVolume(
    double volume, {
    int channel = 0,
    int lane = 0,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneAt(lane).volume = volume.clamp(0, 1);
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneAt(lane).muted = muted;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneAt(lane).inputChannel = inputChannel;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneAt(lane).outputMask = mask;
    return EngineResult.ok;
  }

  @override
  EngineResult setRecordOffset(int frames) {
    _recordOffsetFrames = frames < 0 ? 0 : frames;
    return EngineResult.ok;
  }

  @override
  EngineResult setQuantize({required bool enabled}) => _requireRunning();

  @override
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) => _requireRunning();

  @override
  EngineResult setTrackMultiple({
    required int channel,
    required int multiple,
  }) => _requireRunning();

  @override
  EngineResult setDefaultMultiple({required int multiple}) => _requireRunning();

  @override
  EngineResult setRecDub({required bool enabled}) => _requireRunning();

  @override
  EngineResult setAutoRecord({required bool enabled}) => _requireRunning();

  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) => _requireRunning();

  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
  }) => _requireRunning();

  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) => _requireRunning();

  @override
  EngineResult setMonitorLaneCount({
    required int input,
    required int count,
  }) => _requireRunning();

  @override
  EngineResult setMonitorLaneOutput({
    required int input,
    required int lane,
    required int mask,
  }) => _requireRunning();

  @override
  EngineResult setMonitorLaneVolume({
    required int input,
    required int lane,
    required double volume,
  }) => _requireRunning();

  @override
  EngineResult setMonitorLaneMute({
    required int input,
    required int lane,
    required bool muted,
  }) => _requireRunning();

  @override
  EngineResult setMonitorLaneFx({
    required int input,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) => _requireRunning();

  @override
  EngineResult setMonitorLaneFxCount({
    required int input,
    required int lane,
    required int count,
  }) => _requireRunning();

  @override
  EngineResult setMonitorLaneFxParam({
    required int input,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) => _requireRunning();

  @override
  Float32List readVisual() => Float32List(0);

  @override
  Float32List readTrackVisual(int channel) => Float32List(0);

  @override
  Float32List exportTrack(int channel) => Float32List(0);

  @override
  EngineResult importTrack(int channel, Float32List pcm) => _requireRunning();

  @override
  EngineResult commitSession(int baseFrames) => _requireRunning();

  @override
  void dispose() {
    _running = false;
    _activeConfig = null;
  }

  EngineResult _requireRunning() =>
      _running ? EngineResult.ok : EngineResult.notRunning;
}

class _MockLane {
  int inputChannel = -1;
  int outputMask = 0x3;
  double volume = 1;
  bool muted = false;
}

class _MockTrack {
  int laneCount = 1;
  final List<_MockLane> _lanes = List<_MockLane>.generate(
    kMaxLanes,
    (_) => _MockLane(),
  );

  _MockLane laneAt(int lane) => _lanes[lane.clamp(0, kMaxLanes - 1)];

  TrackSnapshot snapshot() {
    final lanes = [
      for (var i = 0; i < laneCount; i++)
        LaneSnapshot(
          inputChannel: _lanes[i].inputChannel,
          outputMask: _lanes[i].outputMask,
          volume: _lanes[i].volume,
          muted: _lanes[i].muted,
          lengthFrames: 0,
          rms: 0,
          peak: 0,
        ),
    ];
    final lane0 = lanes.isEmpty ? const LaneSnapshot.empty() : lanes.first;
    final inputMask = lane0.inputChannel >= 0 ? 1 << lane0.inputChannel : 0;
    return TrackSnapshot(
      state: TrackState.empty,
      volume: lane0.volume,
      muted: lane0.muted,
      lengthFrames: 0,
      undoDepth: 0,
      rms: 0,
      peak: 0,
      inputMask: inputMask,
      outputMask: lane0.outputMask,
      lanes: lanes,
    );
  }
}
