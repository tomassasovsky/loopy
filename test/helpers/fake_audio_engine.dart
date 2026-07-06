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

  /// The last value passed to [setMasterGain].
  double? lastMasterGain;

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
  EngineResult setMasterGain(double gain) {
    lastMasterGain = gain;
    return EngineResult.ok;
  }

  @override
  EngineResult setAutoRecord({required bool enabled}) {
    lastAutoRecord = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) =>
      EngineResult.ok;

  @override
  EngineResult setOverdubFeedback(double feedback) => EngineResult.ok;

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

  /// Per-input enabled flag passed to [setMonitorInputEnabled].
  final Map<int, bool> monitorInputEnabled = {};

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) {
    monitorInputEnabled[input] = enabled;
    return EngineResult.ok;
  }

  /// Per-input monitor output mask passed to [setMonitorInputOutput].
  final Map<int, int> monitorOutput = {};

  @override
  EngineResult setMonitorInputOutput({required int input, required int mask}) {
    monitorOutput[input] = mask;
    return EngineResult.ok;
  }

  /// Per-input monitor volume passed to [setMonitorInputVolume].
  final Map<int, double> monitorVolume = {};

  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) {
    monitorVolume[input] = volume;
    return EngineResult.ok;
  }

  /// Per-input monitor mute passed to [setMonitorInputMute].
  final Map<int, bool> monitorMute = {};

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) {
    monitorMute[input] = muted;
    return EngineResult.ok;
  }

  /// Per-(input, index) effect type passed to [setMonitorInputFx].
  final Map<(int, int), TrackEffectType> monitorFx = {};

  /// Per-input active chain length passed to [setMonitorInputFxCount].
  final Map<int, int> monitorFxCount = {};

  /// Per-(input, index, param) value passed to [setMonitorInputFxParam].
  final Map<(int, int, int), double> monitorFxParam = {};

  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) {
    monitorFx[(input, index)] = type;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) {
    monitorFxCount[input] = count;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) {
    monitorFxParam[(input, index, param)] = value;
    return EngineResult.ok;
  }

  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      FxFingerprint.offset;

  @override
  int monitorFxFingerprint({required int input}) => FxFingerprint.offset;

  /// Per-output structural gate passed to [setOutputEnabled].
  final Map<int, bool> outputEnabled = {};

  @override
  EngineResult setOutputEnabled({required int output, required bool enabled}) {
    outputEnabled[output] = enabled;
    return EngineResult.ok;
  }

  @override
  Float32List readVisual() => Float32List(0);

  @override
  Float32List readTrackVisual(int channel) => Float32List(0);

  @override
  Float32List exportTrack(int channel) => Float32List(0);

  @override
  Float32List exportTrackLane(int channel, int lane) => Float32List(0);

  @override
  EngineResult importTrack(int channel, Float32List pcm) => EngineResult.ok;

  @override
  EngineResult commitSession(int baseFrames) => EngineResult.ok;

  // --- Performance recording capture ---

  /// Call counters for [perfArm] / [perfDisarm].
  int perfArmCalls = 0;
  int perfDisarmCalls = 0;

  /// Result returned by [perfArm].
  EngineResult perfArmResult = EngineResult.ok;

  /// Result returned by [perfDisarm].
  EngineResult perfDisarmResult = EngineResult.ok;

  /// The `captureDir` passed to the most recent [perfArm] call.
  String? lastPerfCaptureDir;

  @override
  EngineResult perfArm(String captureDir) {
    perfArmCalls++;
    lastPerfCaptureDir = captureDir;
    return perfArmResult;
  }

  @override
  EngineResult perfDisarm() {
    perfDisarmCalls++;
    return perfDisarmResult;
  }

  // --- Plugin hosting (scan: part 2; slots: part 3) ---

  @override
  EngineResult scanBegin({bool rescan = false}) => EngineResult.ok;

  @override
  PluginScanProgress scanPoll() => PluginScanProgress.empty;

  @override
  List<PluginDescriptor> scanResults() => const [];

  @override
  EngineResult scanCancel() => EngineResult.ok;

  @override
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) => MockPluginSlotHandle('fake-plugin');

  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) => MockPluginSlotHandle('fake-plugin');

  @override
  EngineResult clearLanePlugin({
    required int channel,
    required int lane,
    required int index,
  }) => EngineResult.ok;

  @override
  EngineResult clearMonitorPlugin({required int input, required int index}) =>
      EngineResult.ok;

  @override
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot) => const [];

  @override
  double pluginParamGet(PluginSlotHandle slot, int paramId) => 0;

  @override
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) => null;

  @override
  EngineResult pluginParamSet(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) => EngineResult.ok;

  @override
  EngineResult pluginEditorOpen(PluginSlotHandle slot) => EngineResult.ok;

  @override
  EngineResult pluginEditorClose(PluginSlotHandle slot) => EngineResult.ok;

  @override
  bool pluginEditorIsOpen(PluginSlotHandle slot) => false;

  @override
  Uint8List pluginStateGet(PluginSlotHandle slot) => Uint8List(0);

  @override
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state) =>
      EngineResult.ok;

  @override
  void dispose() => disposeCalls++;
}
