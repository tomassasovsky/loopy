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

  @override
  EngineResult setTrackVolume(double volume, {int channel = 0}) {
    lastVolume = volume;
    lastChannel = channel;
    calls.add('setTrackVolume');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackMute({required bool muted, int channel = 0}) {
    lastMuted = muted;
    lastChannel = channel;
    calls.add('setTrackMute');
    return EngineResult.ok;
  }

  int? lastInputMask;
  int? lastOutputMask;

  @override
  EngineResult setInputMask({required int channel, required int mask}) {
    lastChannel = channel;
    lastInputMask = mask;
    calls.add('setInputMask');
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputMask({required int channel, required int mask}) {
    lastChannel = channel;
    lastOutputMask = mask;
    calls.add('setOutputMask');
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

  int? lastMonitorInputMask;
  int? lastMonitorOutputMask;

  @override
  EngineResult setMonitorInputMask({required int mask}) {
    lastMonitorInputMask = mask;
    calls.add('setMonitorInputMask');
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorOutputMask({required int mask}) {
    lastMonitorOutputMask = mask;
    calls.add('setMonitorOutputMask');
    return EngineResult.ok;
  }

  /// The last track passed to [setMonitorFxTrack] (-1 = not following).
  int? lastMonitorFxTrack;

  @override
  EngineResult setMonitorFxTrack({required int track}) {
    lastMonitorFxTrack = track;
    calls.add('setMonitorFxTrack');
    return EngineResult.ok;
  }

  /// Per-(channel, index) effect type/stage passed to [setTrackFx].
  final Map<(int, int), (TrackEffectType, TrackEffectStage)> trackFx = {};

  /// Per-channel active chain length passed to [setTrackFxCount].
  final Map<int, int> trackFxCount = {};

  /// Per-(channel, index, param) value passed to [setTrackFxParam].
  final Map<(int, int, int), double> trackFxParam = {};

  @override
  EngineResult setTrackFx({
    required int channel,
    required int index,
    required TrackEffectType type,
    required TrackEffectStage stage,
  }) {
    trackFx[(channel, index)] = (type, stage);
    calls.add('setTrackFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxCount({required int channel, required int count}) {
    trackFxCount[channel] = count;
    calls.add('setTrackFxCount');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxParam({
    required int channel,
    required int index,
    required int param,
    required double value,
  }) {
    trackFxParam[(channel, index, param)] = value;
    calls.add('setTrackFxParam');
    return EngineResult.ok;
  }

  /// Per-index monitor-bus effect type passed to [setMonitorFx].
  final Map<int, TrackEffectType> monitorFx = {};

  /// The active monitor-bus chain length passed to [setMonitorFxCount].
  int? monitorFxCount;

  /// Per-(index, param) value passed to [setMonitorFxParam].
  final Map<(int, int), double> monitorFxParam = {};

  @override
  EngineResult setMonitorFx({
    required int index,
    required TrackEffectType type,
  }) {
    monitorFx[index] = type;
    calls.add('setMonitorFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorFxCount({required int count}) {
    monitorFxCount = count;
    calls.add('setMonitorFxCount');
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorFxParam({
    required int index,
    required int param,
    required double value,
  }) {
    monitorFxParam[(index, param)] = value;
    calls.add('setMonitorFxParam');
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
