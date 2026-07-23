import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';

class _FakeLane {
  int inputChannel = -1;
  int outputMask = 0x3;
  double volume = 1;
  bool muted = false;

  /// Ordinal-ordered layer buffers (undo… live … redo). Its length matches the
  /// owning track's `undoDepth + 1 + redoDepth`; a single-layer lane holds just
  /// the live buffer.
  List<Float32List> layers = [Float32List(0)];
}

class _FakeTrack {
  TrackState state = TrackState.empty;
  int multiple = 1;
  int lengthFrames = 0;
  int undoDepth = 0;
  int redoDepth = 0;
  final List<_FakeLane> lanes = [_FakeLane()];

  int get liveIndex => undoDepth;

  // Lane-0 conveniences (the single-lane accessors the setters/seed use).
  double get volume => lanes[0].volume;
  set volume(double v) => lanes[0].volume = v;
  bool get muted => lanes[0].muted;
  set muted(bool m) => lanes[0].muted = m;
  Float32List liveOf(int lane) => lanes[lane].layers[liveIndex];
}

/// A stateful in-memory [AudioEngine] that models the looper state, settings,
/// and per-track PCM closely enough to exercise the session repository's
/// save/load without the native engine.
class FakeSessionEngine implements AudioEngine {
  FakeSessionEngine({this.channels = 1, this.sampleRate = 48000});

  final int channels;
  final int sampleRate;

  final List<_FakeTrack> _tracks = List.generate(4, (_) => _FakeTrack());
  int masterLength = 0;

  // ---- tempo grid + click + count-in (A1/A2, threaded to Session v4 by A7)
  // ----
  // Mutable so a test can seed non-default grid state before calling
  // `SessionRepository.save`, exercising the actual `_sessionFrom` wiring
  // rather than trusting it by inspection. Defaults mirror
  // `EngineSnapshot`'s own tempo-free defaults.
  double tempoBpm = 0;
  TempoSource tempoSource = TempoSource.none;
  int tsNum = 4;
  int tsDen = 4;
  GridDivision quantizeDiv = GridDivision.off;
  ClickMode clickMode = ClickMode.off;
  int clickMask = 0;
  double clickVolume = 1;
  int countInBars = 0;

  /// While > 0, every snapshot reports track 0's undo layer as in flight and
  /// decrements — simulating the punch-out fade-tail/drain window a capture
  /// must wait out.
  int layerInFlightPolls = 0;

  /// Seeds a playing track with [pcm] on lane 0 and sets the base loop length
  /// from it. Seed consistent tracks (same base) — the last call wins.
  void seedTrack(
    int channel,
    Float32List pcm, {
    int multiple = 1,
    double volume = 1,
    bool muted = false,
  }) {
    final frames = pcm.length ~/ channels;
    final track = _tracks[channel]
      ..state = TrackState.playing
      ..multiple = multiple
      ..lengthFrames = frames
      ..undoDepth = 0
      ..redoDepth = 0;
    track.lanes[0]
      ..layers = [pcm]
      ..volume = volume
      ..muted = muted
      ..inputChannel = 0;
    masterLength = frames ~/ multiple;
  }

  /// Seeds a playing single-lane track with an ordinal-ordered [layers] stack
  /// and its shared [undoDepth] / [redoDepth] — exercises overdub-layer capture.
  /// The live buffer is `layers[undoDepth]`.
  void seedLayers(
    int channel,
    List<Float32List> layers, {
    int undoDepth = 0,
    int redoDepth = 0,
    int multiple = 1,
    double volume = 1,
    bool muted = false,
  }) {
    final frames = layers[undoDepth].length ~/ channels;
    final track = _tracks[channel]
      ..state = TrackState.playing
      ..multiple = multiple
      ..lengthFrames = frames
      ..undoDepth = undoDepth
      ..redoDepth = redoDepth;
    track.lanes[0]
      ..layers = List.of(layers)
      ..volume = volume
      ..muted = muted
      ..inputChannel = 0;
    masterLength = frames ~/ multiple;
  }

  /// Adds a further lane [lane] to an already-seeded playing track, so a
  /// multi-lane capture can be exercised. Lanes must share the track's length.
  void seedLane(
    int channel,
    int lane,
    Float32List pcm, {
    double volume = 1,
    bool muted = false,
    int outputMask = 0x3,
    int? inputChannel,
  }) {
    final track = _tracks[channel];
    while (track.lanes.length <= lane) {
      track.lanes.add(_FakeLane());
    }
    track.lanes[lane]
      ..layers = [pcm]
      ..volume = volume
      ..muted = muted
      ..outputMask = outputMask
      ..inputChannel = inputChannel ?? lane;
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
    masterLengthFrames: masterLength,
    tempoBpm: tempoBpm,
    tempoSource: tempoSource,
    tsNum: tsNum,
    tsDen: tsDen,
    quantizeDiv: quantizeDiv,
    clickMode: clickMode,
    clickMask: clickMask,
    clickVolume: clickVolume,
    countInBars: countInBars,
    tracks: [
      for (final (i, t) in _tracks.indexed)
        TrackSnapshot(
          state: t.state,
          volume: t.volume,
          muted: t.muted,
          lengthFrames: t.lengthFrames,
          undoDepth: t.undoDepth,
          redoDepth: t.redoDepth,
          rms: 0,
          peak: 0,
          multiple: t.multiple,
          layerInFlight: i == 0 && _consumeInFlightPoll(),
          lanes: [
            for (final lane in t.lanes)
              LaneSnapshot(
                inputChannel: lane.inputChannel,
                outputMask: lane.outputMask,
                volume: lane.volume,
                muted: lane.muted,
                lengthFrames: t.lengthFrames,
                rms: 0,
                peak: 0,
              ),
          ],
        ),
    ],
  );

  bool _consumeInFlightPoll() {
    if (layerInFlightPolls <= 0) return false;
    layerInFlightPolls--;
    return true;
  }

  @override
  Float32List exportTrack(int channel) =>
      Float32List.fromList(_tracks[channel].liveOf(0));

  @override
  Float32List exportTrackLane(int channel, int lane) {
    final track = _tracks[channel];
    if (lane < 0 || lane >= track.lanes.length) return Float32List(0);
    return Float32List.fromList(track.liveOf(lane));
  }

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) {
    final track = _tracks[channel];
    if (lane < 0 || lane >= track.lanes.length) return Float32List(0);
    final layers = track.lanes[lane].layers;
    if (ordinal < 0 || ordinal >= layers.length) return Float32List(0);
    return Float32List.fromList(layers[ordinal]);
  }

  @override
  EngineResult importTrack(int channel, Float32List pcm) =>
      importTrackLane(channel, 0, pcm);

  @override
  EngineResult importTrackLane(int channel, int lane, Float32List pcm) {
    final track = _tracks[channel];
    if (track.state != TrackState.empty) return EngineResult.invalid;
    while (track.lanes.length <= lane) {
      track.lanes.add(_FakeLane());
    }
    track.lanes[lane].layers = [Float32List.fromList(pcm)];
    track.lengthFrames = pcm.length ~/ channels;
    return EngineResult.ok;
  }

  @override
  EngineResult importLayer(
    int channel,
    int lane,
    int ordinal,
    Float32List pcm,
  ) {
    // Not exercised by the session repository (importing is the looper's job);
    // an inert success keeps the interface satisfied.
    return EngineResult.ok;
  }

  @override
  EngineResult finalizeLayers(int channel, int undoCount, int redoCount) =>
      EngineResult.ok;

  @override
  EngineResult commitSession(int baseFrames) {
    if (baseFrames <= 0) return EngineResult.invalid;
    masterLength = baseFrames;
    for (final track in _tracks) {
      if (track.state == TrackState.empty && track.lengthFrames > 0) {
        track
          ..multiple = track.lengthFrames ~/ baseFrames
          ..state = TrackState.playing;
      }
    }
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    _tracks[channel]
      ..state = TrackState.empty
      ..multiple = 1
      ..lengthFrames = 0
      ..undoDepth = 0
      ..redoDepth = 0
      ..lanes.clear();
    _tracks[channel].lanes.add(_FakeLane());
    if (_tracks.every((t) => t.state == TrackState.empty)) masterLength = 0;
    return EngineResult.ok;
  }

  /// Erases exactly like [clear]. This fake models the session-load path, which
  /// never restores a cleared take, so the restore point is not modelled — the
  /// engine's own tests cover it.
  @override
  EngineResult clearUndoable({int channel = 0}) => clear(channel: channel);

  @override
  bool undoRestoresClear({int channel = 0}) => false;

  @override
  EngineResult setLaneCount({required int channel, required int count}) =>
      EngineResult.ok;

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    _tracks[channel].volume = volume;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    _tracks[channel].muted = muted;
    return EngineResult.ok;
  }

  // ---- unused by SessionRepository: inert defaults ----
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
  EngineResult setRecordOffset(int frames) => EngineResult.ok;
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
  EngineResult setTempo(double bpm) => EngineResult.ok;
  @override
  EngineResult setTimeSignature(int num, int den) => EngineResult.ok;
  @override
  EngineResult tapTempo() => EngineResult.ok;
  @override
  EngineResult setSyncTempo({required bool on}) => EngineResult.ok;
  @override
  EngineResult setQuantizeDiv(GridDivision div) => EngineResult.ok;
  @override
  EngineResult setClickMode(ClickMode mode) => EngineResult.ok;
  @override
  EngineResult setClickOutput(int mask) => EngineResult.ok;
  @override
  EngineResult setClickVolume(double volume) => EngineResult.ok;
  @override
  EngineResult setCountIn(int bars) => EngineResult.ok;
  @override
  EngineResult setTrackLengthPreset({
    required int channel,
    required int bars,
  }) => EngineResult.ok;
  @override
  EngineResult setLooperMode(LooperMode mode) => EngineResult.ok;
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
  EngineResult setMonitorInputOutput({
    required int input,
    required int mask,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputMute({
    required int input,
    required bool muted,
  }) => EngineResult.ok;
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
  EngineResult setOutputEnabled({
    required int output,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult perfArm(String captureDir) => EngineResult.ok;
  @override
  EngineResult perfDisarm() => EngineResult.ok;
  @override
  EngineResult renderBegin(String captureDir) => EngineResult.ok;
  @override
  PerformanceRenderProgress renderPoll() => PerformanceRenderProgress.empty;
  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() => const [];
  @override
  EngineResult renderCancel() => EngineResult.ok;
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
