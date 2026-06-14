import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';

/// A controllable in-memory [AudioEngine] for tests.
///
/// Records interactions and returns scripted results/snapshots, so cubit and
/// widget tests never touch the native audio device.
class FakeAudioEngine implements AudioEngine {
  /// Result returned by [start].
  EngineResult startResult = EngineResult.ok;

  /// Snapshot returned by [snapshot].
  EngineSnapshot nextSnapshot = const EngineSnapshot.initial();

  /// The device name reported while running.
  String runningDeviceName = 'Fake Device';

  bool _running = false;

  /// The most recent config passed to [start].
  EngineConfig? lastConfig;

  /// Call counters for assertions.
  int startCalls = 0;
  int stopCalls = 0;
  int measureLatencyCalls = 0;
  int disposeCalls = 0;
  int recordCalls = 0;
  int stopTrackCalls = 0;
  int playCalls = 0;
  int clearCalls = 0;
  int undoCalls = 0;
  int redoCalls = 0;

  /// Last looper parameter values seen.
  double? lastVolume;
  bool? lastMuted;

  /// Last record offset (latency compensation) applied, in frames.
  int? lastRecordOffset;

  @override
  String get version => 'fake-engine 0.0.0';

  @override
  String get deviceName => _running ? runningDeviceName : '';

  @override
  EngineResult start(EngineConfig config) {
    startCalls++;
    lastConfig = config;
    if (startResult.isOk) _running = true;
    return startResult;
  }

  @override
  EngineResult stop() {
    stopCalls++;
    _running = false;
    return EngineResult.ok;
  }

  @override
  EngineSnapshot snapshot() => nextSnapshot;

  /// Loopback detection result returned by [detectLoopback].
  LoopbackInfo loopback = const LoopbackInfo.none();

  @override
  LoopbackInfo detectLoopback() => loopback;

  /// Devices returned by [enumerateDevices].
  List<AudioDevice> devices = const [];

  @override
  List<AudioDevice> enumerateDevices() => devices;

  /// Drivers returned by [enumerateAsioDrivers].
  List<AudioDevice> asioDrivers = const [];

  @override
  List<AudioDevice> enumerateAsioDrivers() => asioDrivers;

  @override
  EngineResult measureLatency() {
    measureLatencyCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult record({int channel = 0}) {
    recordCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult stopTrack({int channel = 0}) {
    stopTrackCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult play({int channel = 0}) {
    playCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    clearCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult undo({int channel = 0}) {
    undoCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult redo({int channel = 0}) {
    redoCalls++;
    return EngineResult.ok;
  }

  /// Per-channel active lane count passed to [setLaneCount].
  final Map<int, int> laneCount = {};

  @override
  EngineResult setLaneCount({required int channel, required int count}) {
    laneCount[channel] = count;
    return EngineResult.ok;
  }

  /// Per-(channel, lane) volume passed to [setLaneVolume].
  final Map<(int, int), double> laneVol = {};

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    laneVol[(channel, lane)] = volume;
    lastVolume = volume;
    return EngineResult.ok;
  }

  /// Per-(channel, lane) mute passed to [setLaneMute].
  final Map<(int, int), bool> laneMute = {};

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    laneMute[(channel, lane)] = muted;
    lastMuted = muted;
    return EngineResult.ok;
  }

  /// Per-(channel, lane) recorded input channel passed to [setLaneInput].
  final Map<(int, int), int> laneInput = {};

  /// Per-(channel, lane) output mask passed to [setLaneOutput].
  final Map<(int, int), int> laneOutput = {};

  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    laneInput[(channel, lane)] = inputChannel;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    laneOutput[(channel, lane)] = mask;
    return EngineResult.ok;
  }

  @override
  EngineResult setRecordOffset(int frames) {
    lastRecordOffset = frames;
    return EngineResult.ok;
  }

  /// The last value passed to [setQuantize].
  bool? lastQuantize;

  @override
  EngineResult setQuantize({required bool enabled}) {
    lastQuantize = enabled;
    return EngineResult.ok;
  }

  /// Per-track quantize overrides passed to [setTrackQuantize].
  final Map<int, bool?> trackQuantize = {};

  @override
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) {
    trackQuantize[channel] = enabled;
    return EngineResult.ok;
  }

  /// Per-track forced multiples passed to [setTrackMultiple].
  final Map<int, int> trackMultiple = {};

  /// The last value passed to [setDefaultMultiple].
  int? lastDefaultMultiple;

  /// The last values passed to [setRecDub] / [setAutoRecord].
  bool? lastRecDub;
  bool? lastAutoRecord;

  @override
  EngineResult setTrackMultiple({required int channel, required int multiple}) {
    trackMultiple[channel] = multiple;
    return EngineResult.ok;
  }

  @override
  EngineResult setDefaultMultiple({required int multiple}) {
    lastDefaultMultiple = multiple;
    return EngineResult.ok;
  }

  @override
  EngineResult setRecDub({required bool enabled}) {
    lastRecDub = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setAutoRecord({required bool enabled}) {
    lastAutoRecord = enabled;
    return EngineResult.ok;
  }

  /// Per-(channel, lane, index) effect type passed to [setLaneFx].
  final Map<(int, int, int), TrackEffectType> laneFx = {};

  /// Per-(channel, lane) active chain length passed to [setLaneFxCount].
  final Map<(int, int), int> laneFxCount = {};

  /// Per-(channel, lane, index, param) value passed to [setLaneFxParam].
  final Map<(int, int, int, int), double> laneFxParam = {};

  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) {
    laneFx[(channel, lane, index)] = type;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
  }) {
    laneFxCount[(channel, lane)] = count;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) {
    laneFxParam[(channel, lane, index, param)] = value;
    return EngineResult.ok;
  }

  /// Per-input (enabled, outputMask) passed to [setMonitorInput].
  final Map<int, (bool, int)> monitorInput = {};

  @override
  EngineResult setMonitorInput({
    required int input,
    required bool enabled,
    required int outputMask,
  }) {
    monitorInput[input] = (enabled, outputMask);
    return EngineResult.ok;
  }

  /// Per-input dry-send output mask passed to [setMonitorInputDry].
  final Map<int, int> monitorInputDry = {};

  @override
  EngineResult setMonitorInputDry({
    required int input,
    required int dryOutputMask,
  }) {
    monitorInputDry[input] = dryOutputMask;
    return EngineResult.ok;
  }

  /// Per-input monitor volume passed to [setMonitorInputVolume].
  final Map<int, double> monitorInputVolume = {};

  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) {
    monitorInputVolume[input] = volume;
    return EngineResult.ok;
  }

  /// Per-(input, index) effect type passed to [setMonitorInputFx].
  final Map<(int, int), TrackEffectType> monitorInputFx = {};

  /// Per-input active chain length passed to [setMonitorInputFxCount].
  final Map<int, int> monitorInputFxCount = {};

  /// Per-(input, index, param) value passed to [setMonitorInputFxParam].
  final Map<(int, int, int), double> monitorInputFxParam = {};

  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) {
    monitorInputFx[(input, index)] = type;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) {
    monitorInputFxCount[input] = count;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) {
    monitorInputFxParam[(input, index, param)] = value;
    return EngineResult.ok;
  }

  @override
  Float32List readVisual() => Float32List(0);

  @override
  Float32List readTrackVisual(int channel) => Float32List(0);

  @override
  Float32List exportTrack(int channel) => Float32List(0);

  @override
  EngineResult importTrack(int channel, Float32List pcm) => EngineResult.ok;

  @override
  EngineResult commitSession(int baseFrames) => EngineResult.ok;

  @override
  void dispose() => disposeCalls++;
}
