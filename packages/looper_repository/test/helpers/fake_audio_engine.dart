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
  double? lastMasterGain;

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
  EngineResult setMasterGain(double gain) {
    lastMasterGain = gain;
    calls.add('setMasterGain');
    return EngineResult.ok;
  }

  @override
  EngineResult setAutoRecord({required bool enabled}) {
    lastAutoRecord = enabled;
    calls.add('setAutoRecord');
    return EngineResult.ok;
  }

  /// The last values passed to [setLimiter] / [setOverdubFeedback].
  bool? lastLimiterEnabled;
  double? lastLimiterCeiling;
  double? lastOverdubFeedback;

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) {
    lastLimiterEnabled = enabled;
    lastLimiterCeiling = ceiling;
    calls.add('setLimiter');
    return EngineResult.ok;
  }

  @override
  EngineResult setOverdubFeedback(double feedback) {
    lastOverdubFeedback = feedback;
    calls.add('setOverdubFeedback');
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

  /// Per-input enabled flag passed to [setMonitorInputEnabled].
  final Map<int, bool> monitorInputEnabled = {};

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) {
    monitorInputEnabled[input] = enabled;
    calls.add('setMonitorInputEnabled');
    return EngineResult.ok;
  }

  /// Per-input monitor output mask passed to [setMonitorInputOutput].
  final Map<int, int> monitorOutput = {};

  @override
  EngineResult setMonitorInputOutput({required int input, required int mask}) {
    monitorOutput[input] = mask;
    calls.add('setMonitorInputOutput');
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
    calls.add('setMonitorInputVolume');
    return EngineResult.ok;
  }

  /// Per-input monitor mute passed to [setMonitorInputMute].
  final Map<int, bool> monitorMute = {};

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) {
    monitorMute[input] = muted;
    calls.add('setMonitorInputMute');
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
    calls.add('setMonitorInputFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) {
    monitorFxCount[input] = count;
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
    monitorFxParam[(input, index, param)] = value;
    calls.add('setMonitorInputFxParam');
    return EngineResult.ok;
  }

  /// Overridable fingerprints so a test can drive the divergence-detection path
  /// without a real engine; default to the empty-chain basis.
  int laneFingerprint = FxFingerprint.offset;
  int monitorFingerprint = FxFingerprint.offset;

  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      laneFingerprint;

  @override
  int monitorFxFingerprint({required int input}) => monitorFingerprint;

  /// Per-output structural gate passed to [setOutputEnabled].
  final Map<int, bool> outputEnabled = {};

  @override
  EngineResult setOutputEnabled({required int output, required bool enabled}) {
    outputEnabled[output] = enabled;
    calls.add('setOutputEnabled');
    return EngineResult.ok;
  }

  @override
  Float32List exportTrack(int channel) {
    calls.add('exportTrack');
    return Float32List(0);
  }

  /// PCM passed to [importTrack], keyed by channel.
  final Map<int, Float32List> importedTracks = {};

  /// Result returned by [importTrack] once any [importFailCountdown] is spent.
  EngineResult importResult = EngineResult.ok;

  /// If `> 0`, [importTrack] returns [EngineResult.invalid] this many times
  /// (decrementing) before honoring [importResult] — exercises the
  /// posted-clear ack retry in `applySession`.
  int importFailCountdown = 0;

  @override
  EngineResult importTrack(int channel, Float32List pcm) {
    calls.add('importTrack');
    if (importFailCountdown > 0) {
      importFailCountdown--;
      return EngineResult.invalid;
    }
    if (importResult.isOk) importedTracks[channel] = pcm;
    return importResult;
  }

  /// Base frames passed to the last [commitSession].
  int? committedBaseFrames;

  @override
  EngineResult commitSession(int baseFrames) {
    calls.add('commitSession');
    committedBaseFrames = baseFrames;
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

  /// Descriptors returned by [scanResults] once a scan has begun.
  List<PluginDescriptor> pluginScanResults = const [];

  /// Optional override for [scanPoll]; defaults to a finished scan that found
  /// every entry in [pluginScanResults].
  PluginScanProgress? scanProgressOverride;

  /// Result returned by [scanBegin] (set to a non-ok value to exercise the
  /// catalog's begin-failure path).
  EngineResult scanBeginResult = EngineResult.ok;

  bool _scanning = false;

  @override
  EngineResult scanBegin({bool rescan = false}) {
    calls.add('scanBegin');
    if (!scanBeginResult.isOk) return scanBeginResult;
    _scanning = true;
    return scanBeginResult;
  }

  @override
  PluginScanProgress scanPoll() =>
      scanProgressOverride ??
      PluginScanProgress(
        done: true,
        found: pluginScanResults.length,
        scanned: pluginScanResults.length,
        total: pluginScanResults.length,
      );

  @override
  List<PluginDescriptor> scanResults() =>
      _scanning ? pluginScanResults : const [];

  @override
  EngineResult scanCancel() {
    _scanning = false;
    calls.add('scanCancel');
    return EngineResult.ok;
  }

  /// Handle returned by [setLanePlugin] / [setMonitorPlugin]; set to `null` to
  /// simulate a load failure.
  PluginSlotHandle? nextSlotHandle = MockPluginSlotHandle('fake-plugin');

  /// Plugin ids passed to [setLanePlugin], keyed by `(channel, lane, index)`.
  final Map<(int, int, int), String> lanePlugins = {};

  /// Plugin ids passed to [setMonitorPlugin], keyed by `(input, index)`.
  final Map<(int, int), String> monitorPlugins = {};

  /// Param surface returned by [pluginParamInfos] (the loaded plugin's knobs).
  List<PluginParamInfo> nextParamInfos = const [];

  /// Live values [pluginParamGet] returns, keyed by param id — lets a test
  /// simulate an editor moving a param (the D-SYNC inbound read-back).
  final Map<int, double> nextParamValues = {};

  /// Display strings [pluginParamValueText] returns, keyed by
  /// `(paramId, value)` — lets a test seed discrete step labels / continuous
  /// readouts. An absent key returns null (no text), as the real ABI does.
  final Map<(int, double), String> paramValueTexts = {};

  /// Every `(slot, paramId, value)` triple passed to [pluginParamSet], in call
  /// order — so a test can assert the RT-queued sets and their ordering.
  final List<({PluginSlotHandle slot, int paramId, double value})>
  pluginParamSets = [];

  @override
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) {
    calls.add('setLanePlugin');
    lanePlugins[(channel, lane, index)] = pluginId;
    return nextSlotHandle;
  }

  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) {
    calls.add('setMonitorPlugin');
    monitorPlugins[(input, index)] = pluginId;
    return nextSlotHandle;
  }

  @override
  EngineResult clearLanePlugin({
    required int channel,
    required int lane,
    required int index,
  }) {
    calls.add('clearLanePlugin');
    return EngineResult.ok;
  }

  @override
  EngineResult clearMonitorPlugin({required int input, required int index}) {
    calls.add('clearMonitorPlugin');
    return EngineResult.ok;
  }

  @override
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot) {
    calls.add('pluginParamInfos');
    return nextParamInfos;
  }

  @override
  double pluginParamGet(PluginSlotHandle slot, int paramId) {
    calls.add('pluginParamGet');
    return nextParamValues[paramId] ?? 0;
  }

  @override
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    calls.add('pluginParamValueText');
    return paramValueTexts[(paramId, value)];
  }

  @override
  EngineResult pluginParamSet(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    calls.add('pluginParamSet');
    pluginParamSets.add((slot: slot, paramId: paramId, value: value));
    return EngineResult.ok;
  }

  /// Slots whose (fake) native editor is currently open.
  final Set<PluginSlotHandle> openEditors = {};

  @override
  EngineResult pluginEditorOpen(PluginSlotHandle slot) {
    calls.add('pluginEditorOpen');
    openEditors.add(slot);
    return EngineResult.ok;
  }

  @override
  EngineResult pluginEditorClose(PluginSlotHandle slot) {
    calls.add('pluginEditorClose');
    openEditors.remove(slot);
    return EngineResult.ok;
  }

  @override
  bool pluginEditorIsOpen(PluginSlotHandle slot) => openEditors.contains(slot);

  /// Fake opaque state returned by [pluginStateGet] (configure per test); the
  /// last blob passed to [pluginStateSet] is recorded for assertions.
  Uint8List nextState = Uint8List(0);
  final List<Uint8List> stateSets = [];

  @override
  Uint8List pluginStateGet(PluginSlotHandle slot) {
    calls.add('pluginStateGet');
    return nextState;
  }

  @override
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state) {
    calls.add('pluginStateSet');
    stateSets.add(state);
    return EngineResult.ok;
  }
}
