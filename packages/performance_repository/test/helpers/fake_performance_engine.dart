import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';

class _FakeLane {
  double volume = 1;
  bool muted = false;
  int lengthFrames = 0;
  Float32List pcm = Float32List(0);
}

class _FakeTrack {
  TrackState state = TrackState.empty;
  double volume = 1;
  bool muted = false;
  int multiple = 1;
  final List<_FakeLane> lanes = [];
}

/// A controllable in-memory [AudioEngine] for `performance_repository` tests:
/// models per-lane PCM/state closely enough to exercise arm/disarm/
/// persistLiveLanes without the native engine, plus the perf-capture surface
/// (armed flag, captureDir, forced result codes).
class FakePerformanceEngine implements AudioEngine {
  FakePerformanceEngine({this.sampleRate = 48000});

  final int sampleRate;

  final List<_FakeTrack> _tracks = List.generate(4, (_) => _FakeTrack());

  int masterLengthFrames = 0;
  int masterPositionFrames = 0;
  double masterGain = 1;
  int recordOffsetFrames = 0;

  bool perfArmed = false;
  String? lastPerfCaptureDir;
  EngineResult perfArmResult = EngineResult.ok;
  EngineResult perfDisarmResult = EngineResult.ok;
  int perfArmCalls = 0;
  int perfDisarmCalls = 0;
  int perfFrames = 0;
  int perfOverruns = 0;

  /// Seeds track [channel] lane [lane] with settled [pcm] (state defaults to
  /// [TrackState.playing] — a settled, exportable lane).
  void seedLane(
    int channel,
    int lane,
    Float32List pcm, {
    TrackState trackState = TrackState.playing,
    double volume = 1,
    bool muted = false,
    int multiple = 1,
  }) {
    final track = _tracks[channel]
      ..state = trackState
      ..volume = volume
      ..muted = muted
      ..multiple = multiple;
    while (track.lanes.length <= lane) {
      track.lanes.add(_FakeLane());
    }
    track.lanes[lane]
      ..pcm = pcm
      ..lengthFrames = pcm.length;
  }

  /// Marks track [channel] as mid-capture (no stable PCM), ensuring it has
  /// [lanes] active lanes, by putting the whole track in [state] — either
  /// [TrackState.overdubbing] (the default) or [TrackState.recording]. The
  /// fake's `_captureSettledLanes`-equivalent rule treats both identically,
  /// matching the production repository.
  void markCapturing(
    int channel, {
    int lanes = 1,
    TrackState state = TrackState.overdubbing,
  }) {
    final track = _tracks[channel]..state = state;
    while (track.lanes.length < lanes) {
      track.lanes.add(_FakeLane());
    }
  }

  @override
  EngineSnapshot snapshot() => EngineSnapshot(
    isRunning: true,
    sampleRate: sampleRate,
    bufferFrames: 128,
    framesProcessed: 0,
    xrunCount: 0,
    inputRms: 0,
    inputPeak: 0,
    outputRms: 0,
    latencyState: LatencyState.idle,
    measuredLatencyMs: -1,
    masterLengthFrames: masterLengthFrames,
    masterPositionFrames: masterPositionFrames,
    masterGain: masterGain,
    recordOffsetFrames: recordOffsetFrames,
    isPerfArmed: perfArmed,
    perfFrames: perfFrames,
    perfOverruns: perfOverruns,
    tracks: [
      for (final t in _tracks)
        TrackSnapshot(
          state: t.state,
          volume: t.volume,
          muted: t.muted,
          lengthFrames: t.lanes.isEmpty ? 0 : t.lanes[0].lengthFrames,
          undoDepth: 0,
          rms: 0,
          peak: 0,
          multiple: t.multiple,
          lanes: [
            for (final l in t.lanes)
              LaneSnapshot(
                inputChannel: 0,
                outputMask: 0x3,
                volume: l.volume,
                muted: l.muted,
                lengthFrames: l.lengthFrames,
                rms: 0,
                peak: 0,
              ),
          ],
        ),
    ],
  );

  @override
  Float32List exportTrack(int channel) => _tracks[channel].lanes.isEmpty
      ? Float32List(0)
      : Float32List.fromList(_tracks[channel].lanes[0].pcm);

  @override
  Float32List exportTrackLane(int channel, int lane) {
    final lanes = _tracks[channel].lanes;
    if (lane < 0 || lane >= lanes.length) return Float32List(0);
    return Float32List.fromList(lanes[lane].pcm);
  }

  @override
  EngineResult importTrack(int channel, Float32List pcm) => EngineResult.ok;

  @override
  EngineResult commitSession(int baseFrames) => EngineResult.ok;

  @override
  EngineResult perfArm(String captureDir) {
    perfArmCalls++;
    lastPerfCaptureDir = captureDir;
    if (!perfArmResult.isOk) return perfArmResult;
    perfArmed = true;
    return EngineResult.ok;
  }

  @override
  EngineResult perfDisarm() {
    perfDisarmCalls++;
    if (!perfDisarmResult.isOk) return perfDisarmResult;
    perfArmed = false;
    return EngineResult.ok;
  }

  int renderBeginCalls = 0;
  String? lastRenderCaptureDir;
  EngineResult renderBeginResult = EngineResult.ok;
  List<PerformanceRenderTrackStatus> mockRenderTrackStatuses = const [];
  bool _renderStarted = false;

  @override
  EngineResult renderBegin(String captureDir) {
    renderBeginCalls++;
    lastRenderCaptureDir = captureDir;
    if (!renderBeginResult.isOk) return renderBeginResult;
    _renderStarted = true;
    return EngineResult.ok;
  }

  @override
  PerformanceRenderProgress renderPoll() => PerformanceRenderProgress.empty;

  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() =>
      _renderStarted ? mockRenderTrackStatuses : const [];

  @override
  EngineResult renderCancel() {
    _renderStarted = false;
    return EngineResult.ok;
  }

  // ---- unused by PerformanceRepository: inert defaults ----
  @override
  String get version => 'fake';
  @override
  String get deviceName => 'fake';
  @override
  EngineResult start(EngineConfig config) => EngineResult.ok;
  @override
  EngineResult stop() => EngineResult.ok;
  @override
  LoopbackInfo detectLoopback() => const LoopbackInfo.none();
  @override
  List<AudioDevice> enumerateDevices() => const [];
  @override
  List<AudioDevice> enumerateAsioDrivers() => const [];
  @override
  EngineResult measureLatency() => EngineResult.ok;
  @override
  EngineResult record({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult stopTrack({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult play({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult undo({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult redo({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult clear({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult setRecordOffset(int frames) => EngineResult.ok;
  @override
  EngineResult setLaneCount({required int channel, required int count}) =>
      EngineResult.ok;
  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) =>
      EngineResult.ok;
  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) => EngineResult.ok;
  @override
  EngineResult setQuantize({required bool enabled}) => EngineResult.ok;
  @override
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackMultiple({
    required int channel,
    required int multiple,
  }) => EngineResult.ok;
  @override
  EngineResult setDefaultMultiple({required int multiple}) => EngineResult.ok;
  @override
  EngineResult setRecDub({required bool enabled}) => EngineResult.ok;
  @override
  EngineResult setMasterGain(double gain) => EngineResult.ok;
  @override
  EngineResult setAutoRecord({required bool enabled}) => EngineResult.ok;
  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) =>
      EngineResult.ok;
  @override
  EngineResult setOverdubFeedback(double feedback) => EngineResult.ok;
  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputOutput({required int input, required int mask}) =>
      EngineResult.ok;
  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) =>
      EngineResult.ok;
  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;
  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      FxFingerprint.offset;
  @override
  int monitorFxFingerprint({required int input}) => FxFingerprint.offset;
  @override
  EngineResult setOutputEnabled({required int output, required bool enabled}) =>
      EngineResult.ok;
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
  }) => null;
  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) => null;
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
  Float32List readVisual() => Float32List(0);
  @override
  Float32List readTrackVisual(int channel) => Float32List(0);
  @override
  void dispose() {}
}
