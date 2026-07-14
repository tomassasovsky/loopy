import 'dart:typed_data';

import 'package:loopy_engine/src/audio_device.dart';
import 'package:loopy_engine/src/audio_engine.dart';
import 'package:loopy_engine/src/engine_config.dart';
import 'package:loopy_engine/src/engine_snapshot.dart';
import 'package:loopy_engine/src/fx_fingerprint.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:loopy_engine/src/loopback_info.dart';
import 'package:loopy_engine/src/performance_render_progress.dart';
import 'package:loopy_engine/src/plugin_descriptor.dart';
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
  double _masterGain = 1;
  bool _perfArmed = false;
  int _perfFrames = 0;

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
    _masterGain = 1; // unity on every fresh start, mirroring the native engine
    _perfArmed = false; // disarmed on every fresh start/reconfigure
    _perfFrames = 0;
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
      if (_perfArmed) _perfFrames += buffer;
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
      masterGain: _masterGain,
      // The mock echoes the requested backend as the negotiated one (ASIO
      // "succeeds"), so the requested-ASIO/reality-miniaudio fallback is NOT
      // exercised here — the widget test seeds that state directly.
      activeBackend: _running
          ? (_activeConfig?.backend ?? AudioBackend.miniaudio)
          : AudioBackend.miniaudio,
      isPerfArmed: _perfArmed,
      perfFrames: _perfFrames,
      // perfOverruns defaults to 0: the mock models no ring capacity, so
      // nothing ever overflows.
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

  /// Deterministic fixed scan result for UI development and tests: one VST3 and
  /// one CLAP plugin, plus one failed entry (empty id) so the failed-scan path
  /// can be exercised without real hardware.
  static const List<PluginDescriptor> mockScanResults = [
    PluginDescriptor(
      id: '0102030405060708090A0B0C0D0E0F10',
      name: 'Mock Reverb',
      vendor: 'Loopy Labs',
      path: '/Library/Audio/Plug-Ins/VST3/Mock Reverb.vst3',
      format: PluginFormat.vst3,
      version: 0x00010200, // 1.2.0
    ),
    PluginDescriptor(
      id: 'com.loopy.mock-delay',
      name: 'Mock Delay',
      vendor: 'Loopy Labs',
      path: '/Library/Audio/Plug-Ins/CLAP/Mock Delay.clap',
      format: PluginFormat.clap,
      version: 0x00000300, // 0.3.0
    ),
    PluginDescriptor(
      id: '', // failed entry
      name: 'Broken Plugin.clap',
      vendor: '',
      path: '/Library/Audio/Plug-Ins/CLAP/Broken Plugin.clap',
      format: PluginFormat.clap,
      version: 0,
    ),
  ];

  bool _scanStarted = false;

  @override
  EngineResult scanBegin({bool rescan = false}) {
    _scanStarted = true;
    return EngineResult.ok;
  }

  @override
  PluginScanProgress scanPoll() => _scanStarted
      ? PluginScanProgress(
          done: true,
          found: mockScanResults.length,
          scanned: mockScanResults.length,
          total: mockScanResults.length,
        )
      : PluginScanProgress.empty;

  @override
  List<PluginDescriptor> scanResults() =>
      _scanStarted ? mockScanResults : const [];

  @override
  EngineResult scanCancel() {
    _scanStarted = false;
    return EngineResult.ok;
  }

  @override
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) => MockPluginSlotHandle(pluginId);

  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) => MockPluginSlotHandle(pluginId);

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
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot) =>
      MockPluginSlotHandle.mockParams;

  @override
  double pluginParamGet(PluginSlotHandle slot, int paramId) {
    if (slot is! MockPluginSlotHandle) return 0;
    return slot.paramValue(paramId);
  }

  @override
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    if (slot is! MockPluginSlotHandle) return null;
    return slot.paramValueText(paramId, value);
  }

  @override
  EngineResult pluginParamSet(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    if (slot is! MockPluginSlotHandle) return EngineResult.invalid;
    return slot.setParamValue(paramId, value);
  }

  @override
  EngineResult pluginEditorOpen(PluginSlotHandle slot) {
    if (slot is! MockPluginSlotHandle) return EngineResult.invalid;
    slot.editorOpen = true;
    return EngineResult.ok;
  }

  @override
  EngineResult pluginEditorClose(PluginSlotHandle slot) {
    if (slot is! MockPluginSlotHandle) return EngineResult.invalid;
    slot.editorOpen = false;
    return EngineResult.ok;
  }

  @override
  bool pluginEditorIsOpen(PluginSlotHandle slot) =>
      slot is MockPluginSlotHandle && slot.editorOpen;

  @override
  Uint8List pluginStateGet(PluginSlotHandle slot) =>
      slot is MockPluginSlotHandle ? slot.stateBlob : Uint8List(0);

  @override
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state) {
    if (slot is! MockPluginSlotHandle) return EngineResult.invalid;
    slot.stateBlob = Uint8List.fromList(state);
    return EngineResult.ok;
  }

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
    _tracks[channel].laneAt(lane).volume = volume.clamp(0.0, LE_MAX_GAIN);
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
  EngineResult setMasterGain(double gain) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _masterGain = gain.clamp(0.0, 1.0);
    return EngineResult.ok;
  }

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) =>
      _requireRunning();

  @override
  EngineResult setOutputEnabled({
    required int output,
    required bool enabled,
  }) => _requireRunning();

  @override
  EngineResult setOverdubFeedback(double feedback) => _requireRunning();

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
  EngineResult setMonitorInputOutput({
    required int input,
    required int mask,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputMute({
    required int input,
    required bool muted,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) => _requireRunning();

  // The mock runs no DSP and holds no engine-side chain, so every chain
  // fingerprints to the empty-chain basis (the repository owns the real cache).
  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      FxFingerprint.offset;

  @override
  int monitorFxFingerprint({required int input}) => FxFingerprint.offset;

  @override
  Float32List readVisual() => Float32List(0);

  @override
  Float32List readTrackVisual(int channel) => Float32List(0);

  @override
  Float32List exportTrack(int channel) => Float32List(0);

  @override
  Float32List exportTrackLane(int channel, int lane) => Float32List(0);

  @override
  EngineResult importTrack(int channel, Float32List pcm) => _requireRunning();

  @override
  EngineResult importTrackLane(int channel, int lane, Float32List pcm) =>
      _requireRunning();

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) => Float32List(0);

  @override
  EngineResult importLayer(
    int channel,
    int lane,
    int ordinal,
    Float32List pcm,
  ) => _requireRunning();

  @override
  EngineResult finalizeLayers(int channel, int undoCount, int redoCount) =>
      _requireRunning();

  @override
  EngineResult commitSession(int baseFrames) => _requireRunning();

  /// The `captureDir` passed to the most recent [perfArm] call, for test
  /// assertions. `null` until the first arm.
  String? lastPerfCaptureDir;

  @override
  EngineResult perfArm(String captureDir) {
    if (captureDir.isEmpty) return EngineResult.invalid;
    final result = _requireRunning();
    if (!result.isOk) return result;
    _perfArmed = true; // idempotent: re-arming just keeps it armed
    lastPerfCaptureDir = captureDir;
    return EngineResult.ok;
  }

  @override
  EngineResult perfDisarm() {
    _perfArmed = false; // idempotent: disarming an unarmed mock is a no-op
    return EngineResult.ok;
  }

  /// The `captureDir` passed to the most recent [renderBegin] call, for test
  /// assertions. `null` until the first render.
  String? lastRenderCaptureDir;

  /// The per-track outcomes [renderTrackStatuses] reports once a render has
  /// started — set this before calling [renderBegin] to model a specific
  /// scenario (e.g. a partial-success render).
  List<PerformanceRenderTrackStatus> mockRenderTrackStatuses = const [];

  bool _renderStarted = false;

  @override
  EngineResult renderBegin(String captureDir) {
    if (captureDir.isEmpty) return EngineResult.invalid;
    if (_renderStarted) return EngineResult.alreadyRunning;
    _renderStarted = true;
    lastRenderCaptureDir = captureDir;
    return EngineResult.ok;
  }

  @override
  PerformanceRenderProgress renderPoll() =>
      // The mock has no real worker thread — a "started" render is already
      // done, 100%, the instant it starts. That happens to be the same value
      // as "never started" (PerformanceRenderProgress.empty), so there is
      // nothing for _renderStarted to distinguish here; it still gates
      // renderTrackStatuses below.
      PerformanceRenderProgress.empty;

  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() =>
      _renderStarted ? mockRenderTrackStatuses : const [];

  @override
  EngineResult renderCancel() {
    _renderStarted = false;
    return EngineResult.ok;
  }

  @override
  void dispose() {
    _running = false;
    _activeConfig = null;
  }

  EngineResult _requireRunning() =>
      _running ? EngineResult.ok : EngineResult.notRunning;
}

/// A deterministic [PluginSlotHandle] returned by [MockAudioEngine], carrying
/// the loaded plugin id so tests and UI development can assert on it, plus a
/// small set of fake parameters with mutable values.
class MockPluginSlotHandle implements PluginSlotHandle {
  /// Creates a [MockPluginSlotHandle] for [pluginId], seeded with the default
  /// value of each [mockParams] entry.
  MockPluginSlotHandle(this.pluginId)
    : _values = {for (final p in mockParams) p.id: p.def},
      stateBlob = Uint8List.fromList('mock-state:$pluginId'.codeUnits);

  /// The id of the plugin this handle was loaded from.
  final String pluginId;

  final Map<int, double> _values;

  /// Whether this slot's (fake) native editor window is open. Toggled by
  /// [MockAudioEngine.pluginEditorOpen] / `pluginEditorClose`.
  bool editorOpen = false;

  /// The slot's fake opaque state — deterministic + non-empty (derived from
  /// [pluginId]) so D-P1 capture/restore round-trips in tests.
  Uint8List stateBlob;

  /// The deterministic fake parameter set every mock plugin exposes: three
  /// automatable knobs ranged 0..1, mirroring the native StubHost.
  static const List<PluginParamInfo> mockParams = [
    PluginParamInfo(
      id: 100,
      name: 'Mock Gain',
      unit: 'dB',
      min: 0,
      max: 1,
      def: 0.5,
      stepCount: 0,
      flags: 0x01, // automatable
    ),
    PluginParamInfo(
      id: 200,
      name: 'Mock Tone',
      unit: '',
      min: 0,
      max: 1,
      def: 0.5,
      stepCount: 0,
      flags: 0x01,
    ),
    PluginParamInfo(
      id: 300,
      name: 'Mock Mix',
      unit: '',
      min: 0,
      max: 1,
      def: 0.5,
      stepCount: 0,
      flags: 0x01,
    ),
  ];

  /// The current value of parameter [paramId], or `0` if unknown.
  double paramValue(int paramId) => _values[paramId] ?? 0;

  /// A deterministic display string for [paramId] at [value] (the value in the
  /// param's own unit), or null for an unknown id — the mock stand-in for the
  /// plugin's own value-to-text formatting.
  String? paramValueText(int paramId, double value) {
    for (final param in mockParams) {
      if (param.id != paramId) continue;
      final text = value.toStringAsFixed(2);
      return param.unit.isEmpty ? text : '$text ${param.unit}';
    }
    return null;
  }

  /// Sets parameter [paramId] to [value]; unknown ids report invalid.
  EngineResult setParamValue(int paramId, double value) {
    if (!_values.containsKey(paramId)) return EngineResult.invalid;
    _values[paramId] = value;
    return EngineResult.ok;
  }
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
