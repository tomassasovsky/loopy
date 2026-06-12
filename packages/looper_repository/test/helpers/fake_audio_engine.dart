import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';

/// A controllable in-memory [AudioEngine] for repository tests.
class FakeAudioEngine implements AudioEngine {
  /// Snapshot returned by [snapshot] (mutate between ticks in tests).
  EngineSnapshot nextSnapshot = const EngineSnapshot.initial();

  /// Device name reported by [deviceName].
  String deviceNameValue = 'Fake Device';

  /// Records the command names forwarded to the engine, in order.
  final List<String> calls = <String>[];

  double? lastVolume;
  bool? lastMuted;
  EngineConfig? lastConfig;

  /// Result returned by [start].
  EngineResult startResult = EngineResult.ok;

  @override
  String get version => 'fake-engine';

  @override
  String get deviceName => deviceNameValue;

  @override
  EngineResult start(EngineConfig config) {
    lastConfig = config;
    calls.add('start');
    return startResult;
  }

  @override
  EngineResult stop() {
    calls.add('stop');
    return EngineResult.ok;
  }

  @override
  EngineSnapshot snapshot() => nextSnapshot;

  /// Loopback detection result returned by [detectLoopback].
  LoopbackInfo loopback = const LoopbackInfo.none();

  @override
  LoopbackInfo detectLoopback() {
    calls.add('detectLoopback');
    return loopback;
  }

  /// Devices returned by [enumerateDevices].
  List<AudioDevice> devices = const [];

  @override
  List<AudioDevice> enumerateDevices() {
    calls.add('enumerateDevices');
    return devices;
  }

  /// Drivers returned by [enumerateAsioDrivers].
  List<AudioDevice> asioDrivers = const [];

  @override
  List<AudioDevice> enumerateAsioDrivers() {
    calls.add('enumerateAsioDrivers');
    return asioDrivers;
  }

  @override
  EngineResult measureLatency() {
    calls.add('measureLatency');
    return EngineResult.ok;
  }

  /// Last channel seen by a channel-scoped command.
  int? lastChannel;

  @override
  EngineResult record({int channel = 0}) {
    lastChannel = channel;
    calls.add('record');
    return EngineResult.ok;
  }

  @override
  EngineResult stopTrack({int channel = 0}) {
    lastChannel = channel;
    calls.add('stopTrack');
    return EngineResult.ok;
  }

  @override
  EngineResult play({int channel = 0}) {
    lastChannel = channel;
    calls.add('play');
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    lastChannel = channel;
    calls.add('clear');
    return EngineResult.ok;
  }

  @override
  EngineResult undo({int channel = 0}) {
    lastChannel = channel;
    calls.add('undo');
    return EngineResult.ok;
  }

  @override
  EngineResult redo({int channel = 0}) {
    lastChannel = channel;
    calls.add('redo');
    return EngineResult.ok;
  }

  /// Per-channel active lane count passed to [setLaneCount].
  final Map<int, int> laneCount = {};

  @override
  EngineResult setLaneCount({required int channel, required int count}) {
    laneCount[channel] = count;
    calls.add('setLaneCount');
    return EngineResult.ok;
  }

  /// Per-(channel, lane) volume passed to [setLaneVolume].
  final Map<(int, int), double> laneVol = {};

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    laneVol[(channel, lane)] = volume;
    lastVolume = volume;
    lastChannel = channel;
    calls.add('setLaneVolume');
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
    lastChannel = channel;
    calls.add('setLaneMute');
    return EngineResult.ok;
  }

  /// Per-(channel, lane) recorded input channel passed to [setLaneInput].
  final Map<(int, int), int> laneInput = {};

  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    laneInput[(channel, lane)] = inputChannel;
    lastChannel = channel;
    calls.add('setLaneInput');
    return EngineResult.ok;
  }

  /// Per-(channel, lane) output mask passed to [setLaneOutput].
  final Map<(int, int), int> laneOutput = {};

  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    laneOutput[(channel, lane)] = mask;
    lastChannel = channel;
    calls.add('setLaneOutput');
    return EngineResult.ok;
  }

  int? lastRecordOffset;

  @override
  EngineResult setRecordOffset(int frames) {
    lastRecordOffset = frames;
    calls.add('setRecordOffset');
    return EngineResult.ok;
  }

  bool? lastQuantize;

  @override
  EngineResult setQuantize({required bool enabled}) {
    lastQuantize = enabled;
    calls.add('setQuantize');
    return EngineResult.ok;
  }

  final Map<int, bool?> trackQuantize = {};

  @override
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) {
    trackQuantize[channel] = enabled;
    calls.add('setTrackQuantize');
    return EngineResult.ok;
  }

  final Map<int, int> trackMultiple = {};
  int? lastDefaultMultiple;
  bool? lastRecDub;
  bool? lastAutoRecord;

  @override
  EngineResult setTrackMultiple({required int channel, required int multiple}) {
    trackMultiple[channel] = multiple;
    calls.add('setTrackMultiple');
    return EngineResult.ok;
  }

  @override
  EngineResult setDefaultMultiple({required int multiple}) {
    lastDefaultMultiple = multiple;
    calls.add('setDefaultMultiple');
    return EngineResult.ok;
  }

  @override
  EngineResult setRecDub({required bool enabled}) {
    lastRecDub = enabled;
    calls.add('setRecDub');
    return EngineResult.ok;
  }

  @override
  EngineResult setAutoRecord({required bool enabled}) {
    lastAutoRecord = enabled;
    calls.add('setAutoRecord');
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
    calls.add('setLaneFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
  }) {
    laneFxCount[(channel, lane)] = count;
    calls.add('setLaneFxCount');
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
    calls.add('setLaneFxParam');
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
    calls.add('setMonitorInput');
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
    calls.add('setMonitorInputDry');
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
    calls.add('setMonitorInputFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) {
    monitorInputFxCount[input] = count;
    calls.add('setMonitorInputFxCount');
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
    calls.add('setMonitorInputFxParam');
    return EngineResult.ok;
  }

  @override
  Float32List exportTrack(int channel) {
    calls.add('exportTrack');
    return Float32List(0);
  }

  @override
  EngineResult importTrack(int channel, Float32List pcm) {
    calls.add('importTrack');
    return EngineResult.ok;
  }

  @override
  EngineResult commitSession(int baseFrames) {
    calls.add('commitSession');
    return EngineResult.ok;
  }

  @override
  void dispose() => calls.add('dispose');

  /// Waveform returned by [readVisual] (mutate in tests).
  Float32List visual = Float32List(0);

  @override
  Float32List readVisual() {
    calls.add('readVisual');
    return visual;
  }

  @override
  Float32List readTrackVisual(int channel) {
    calls.add('readTrackVisual');
    return visual;
  }
}
