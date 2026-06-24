import 'dart:async';
import 'dart:typed_data';

import 'package:looper_repository/src/models/audio_config.dart';
import 'package:looper_repository/src/models/engine_status.dart';
import 'package:looper_repository/src/models/lane.dart';
import 'package:looper_repository/src/models/looper_state.dart';
import 'package:looper_repository/src/models/plugin_descriptor.dart'
    show pluginParamInfoFromEngine;
import 'package:looper_repository/src/models/track.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:looper_repository/src/models/transport_state.dart';
import 'package:loopy_engine/loopy_engine.dart'
    hide
        AudioBackend,
        AudioDevice,
        BuiltInEffect,
        EngineConfig,
        LatencyState,
        LoopbackInfo,
        LoopbackKind,
        ParamReadout,
        PluginEffect,
        PluginParamInfo,
        PluginRef,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType;

/// Builds the production [AudioEngine] backed by the native loopy engine.
///
/// Lets the composition root obtain an engine without naming or importing the
/// engine package's concrete types: the returned value is held as the
/// [AudioEngine] interface and handed straight to [LooperRepository] /
/// `SessionRepository`.
AudioEngine createNativeAudioEngine() => NativeAudioEngine();

/// Builds a deterministic mock [AudioEngine] for the mock flavor, plus the
/// domain [EngineConfig] mirroring the mock's defaults so the caller can
/// auto-start straight into the looper.
///
/// The mock's own engine-typed default config is read field-by-field and mapped
/// to the domain [EngineConfig] here, so neither the caller nor this signature
/// ever names the engine's config type.
({AudioEngine engine, EngineConfig startConfig}) createMockEngine() {
  final engine = MockAudioEngine();
  final defaults = engine.defaultConfig;
  return (
    engine: engine,
    startConfig: EngineConfig(
      sampleRate: defaults.sampleRate,
      bufferFrames: defaults.bufferFrames,
      inputChannels: defaults.inputChannels,
      outputChannels: defaults.outputChannels,
      playbackDeviceId: defaults.playbackDeviceId,
      captureDeviceId: defaults.captureDeviceId,
    ),
  );
}

/// Owns the [AudioEngine] and is the single source of looper truth.
///
/// Polls the engine snapshot on a ticker, projects it into a [LooperState], and
/// publishes distinct states on [looperState]. Looper commands are forwarded to
/// the engine. The bloc layer depends on this repository, never on the engine.
class LooperRepository {
  /// Creates a [LooperRepository] driving [engine].
  ///
  /// [ticker] drives snapshot polling; when omitted a periodic stream at
  /// [pollInterval] (~60 Hz) is used. Injecting a ticker makes tests
  /// deterministic.
  LooperRepository({
    required AudioEngine engine,
    Stream<void>? ticker,
    Duration pollInterval = const Duration(milliseconds: 16),
    Stream<void>? reconnectTicker,
    Duration reconnectInterval = const Duration(seconds: 1),
  }) : _engine = engine,
       _ticker = ticker,
       _pollInterval = pollInterval,
       _reconnectTicker = reconnectTicker,
       _reconnectInterval = reconnectInterval {
    _controller = StreamController<LooperState>.broadcast(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
  }

  final AudioEngine _engine;
  final Stream<void>? _ticker;
  Duration _pollInterval;
  final Stream<void>? _reconnectTicker;
  final Duration _reconnectInterval;
  late final StreamController<LooperState> _controller;
  StreamSubscription<void>? _tickerSub;
  Timer? _pollTimer;
  LooperState? _last;
  EngineConfig? _lastEngineConfig;

  /// Whether the user intends the engine to be running (set on a successful
  /// [startEngine], cleared on [stopEngine]). The reconnect supervisor only
  /// recovers a device the user did not deliberately stop.
  bool _intendRunning = false;

  /// The desired quantize-recording state, re-applied to the engine on every
  /// successful (re)start so it survives device changes and reconnects.
  bool _quantize = false;

  /// Per-track quantize overrides (absent => inherit the global default).
  /// Remembered and re-applied on every successful (re)start.
  final Map<int, bool> _trackQuantize = {};

  /// Per-track forced loop multiples (absent => auto). The global rec/dub and
  /// auto-record (sound-activated) flags. All re-applied on every (re)start.
  final Map<int, int> _trackMultiple = {};
  int _defaultMultiple = 0;
  bool _recDub = false;
  bool _autoRecord = false;

  /// The desired global master output gain (`0..1`), re-applied to the engine
  /// on every successful (re)start so it survives device changes and
  /// reconnects. Unity (`1.0`) until set.
  double _masterGain = 1;

  /// Per-track active lane count (absent => 1). Remembered and re-applied on
  /// every successful (re)start.
  final Map<int, int> _laneCount = {};

  /// Per-(channel, lane) recorded input channel (`-1` = none), output mask,
  /// volume, mute, and effect chain — each remembered and re-applied on every
  /// successful (re)start so they survive device changes / reconnects.
  final Map<(int, int), int> _laneInput = {};
  final Map<(int, int), int> _laneOutput = {};
  final Map<(int, int), double> _laneVolume = {};
  final Map<(int, int), bool> _laneMute = {};
  final Map<(int, int), List<TrackEffect>> _laneEffects = {};

  /// Per-hardware-input live monitor enable flag (absent => disabled). The
  /// input-level gate; per-lane routing / mix / effects live in the maps below.
  /// All re-applied on every successful (re)start so they survive device
  /// changes / reconnects.
  final Map<int, bool> _monitorInputEnabled = {};

  /// Per-input monitor output mask, volume, mute, and a single effect chain —
  /// each remembered and re-applied on every successful (re)start. An empty
  /// chain is the clean (dry) path; this chain is what gets snapshot-copied
  /// onto a track lane when recording into the input.
  final Map<int, int> _monitorOutput = {};
  final Map<int, double> _monitorVolume = {};
  final Map<int, bool> _monitorMute = {};
  final Map<int, List<TrackEffect>> _monitorEffects = {};

  /// Live plugin slot handles keyed by chain position — `(channel, lane,
  /// index)` for lane chains, `(input, index)` for monitor chains. Repopulated
  /// every time a chain is (re)applied to the running engine; an absent entry
  /// means the plugin is not currently loaded (engine stopped, or its load
  /// failed), so a parameter set has nowhere to go. Handles are opaque tokens
  /// the engine owns; the repository never frees them directly.
  final Map<(int, int, int), PluginSlotHandle> _laneSlots = {};
  final Map<(int, int), PluginSlotHandle> _monitorSlots = {};

  /// Structural output gate: outputs the user explicitly turned OFF (absent =>
  /// enabled). Only off entries are stored (default-on, self-cleaning), and
  /// they are re-applied on every successful (re)start so a gated output
  /// survives device changes / reconnects.
  final Map<int, bool> _outputEnabled = {};

  /// Reconnect supervision: while these are non-null a pinned device is absent
  /// and we are polling enumeration to reopen it. Their presence *is* the
  /// "awaiting reconnect" state, so there is no separate flag to keep in sync.
  StreamSubscription<void>? _reconnectSub;
  Timer? _reconnectTimer;

  /// Signature of the device list at the last restart attempt. A failed
  /// restart is not retried until the device list changes (e.g. a re-plug), so
  /// a present but unopenable device cannot thrash the engine.
  String? _lastAttemptSignature;

  bool get _isReconnecting => _reconnectSub != null || _reconnectTimer != null;

  /// Distinct stream of looper states.
  ///
  /// A new subscriber immediately receives the most recent state before live
  /// updates, so a late listener — e.g. a bloc created after the audio-setup
  /// flow already drove the engine to a steady state — shows the current tracks
  /// instead of waiting for the next change.
  Stream<LooperState> get looperState async* {
    final last = _last;
    if (last != null) yield last;
    yield* _controller.stream;
  }

  /// The current state, read synchronously from the engine.
  LooperState get state => _project(_engine.snapshot());

  /// The most recent config passed to [startEngine], or `null` before the first
  /// successful start.
  EngineConfig? get lastEngineConfig => _lastEngineConfig;

  /// The engine + miniaudio version string.
  String get engineVersion => _engine.version;

  void _startPolling() {
    // Polling must survive subscribe/cancel cycles (hot restart, a bloc being
    // rebuilt). An injected ticker (tests) is a broadcast stream and can be
    // re-listened; the default uses a recreatable [Timer] because
    // `Stream.periodic` is single-subscription and cannot be re-listened after
    // [_stopPolling] cancels it.
    final ticker = _ticker;
    if (ticker != null) {
      _tickerSub = ticker.listen((_) => _poll());
    } else {
      _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    }
    _poll();
  }

  void _stopPolling() {
    unawaited(_tickerSub?.cancel());
    _tickerSub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// The current snapshot-poll cadence.
  Duration get pollInterval => _pollInterval;

  /// Updates the snapshot-poll cadence (UI refresh rate). When polling on the
  /// default timer, restarts it at the new [interval] so the change takes
  /// effect immediately; an injected ticker (tests) is unaffected.
  void setPollInterval(Duration interval) {
    if (interval == _pollInterval) return;
    _pollInterval = interval;
    if (_ticker == null && _pollTimer != null) {
      _pollTimer!.cancel();
      _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    }
  }

  void _poll() {
    final snapshot = _engine.snapshot();
    _superviseDevice(devicePresent: snapshot.devicePresent);
    final next = _project(snapshot);
    if (next == _last) return;
    _last = next;
    _controller.add(next);
  }

  /// Re-projects and emits immediately (deduped), skipping the device
  /// supervision the periodic poll does. Used so a local edit — e.g. a lane FX
  /// param the UI drives — reflects on the next frame rather than waiting for
  /// the next poll tick (which would make a dragged knob feel a tick behind).
  void _reproject() {
    final next = _project(_engine.snapshot());
    if (next == _last) return;
    _last = next;
    _controller.add(next);
  }

  /// Watches the pinned device's presence each poll. When a pinned device goes
  /// absent (and the user did not stop the engine), it begins polling
  /// enumeration on the reconnect ticker/timer; when it reappears it stops and
  /// restarts the engine on that device. System default ('' device ids) is
  /// never auto-restarted. Cheap on the hot path: only a bool is checked here;
  /// the expensive enumeration runs on the slower reconnect cadence.
  void _superviseDevice({required bool devicePresent}) {
    if (!_isPinned || !_intendRunning) return;
    if (!devicePresent && !_isReconnecting) {
      _startReconnectPolling();
    } else if (devicePresent && _isReconnecting) {
      _stopReconnectPolling();
    }
  }

  /// Whether the last successful start pinned a specific device (vs the system
  /// default, which is never auto-restarted on transient loss).
  bool get _isPinned {
    final config = _lastEngineConfig;
    return config != null &&
        (config.playbackDeviceId.isNotEmpty ||
            config.captureDeviceId.isNotEmpty);
  }

  void _startReconnectPolling() {
    _lastAttemptSignature = null; // a fresh loss may retry immediately
    final ticker = _reconnectTicker;
    if (ticker != null) {
      _reconnectSub = ticker.listen((_) => _attemptReconnect());
    } else {
      _reconnectTimer = Timer.periodic(
        _reconnectInterval,
        (_) => _attemptReconnect(),
      );
    }
  }

  void _stopReconnectPolling() {
    unawaited(_reconnectSub?.cancel());
    _reconnectSub = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Reopens the pinned device once it reappears in enumeration. A restart is
  /// attempted at most once per distinct device list: if it fails, we wait for
  /// the list to change (e.g. a re-plug) before retrying, so a present-but-
  /// unopenable device cannot thrash the engine. (Engine calls are synchronous,
  /// so no re-entrancy guard is needed.)
  void _attemptReconnect() {
    final config = _lastEngineConfig;
    if (config == null || !_isPinned) {
      _stopReconnectPolling();
      return;
    }
    final devices = _engine
        .enumerateDevices()
        .map(audioDeviceFromEngine)
        .toList();
    if (!_pinnedDevicesPresent(config, devices)) {
      return; // still absent — keep waiting
    }
    final signature = devices
        .map((d) => '${d.isInput ? 'i' : 'o'}:${d.id}')
        .join('|');
    if (signature == _lastAttemptSignature) return; // already tried this set
    _lastAttemptSignature = signature;
    _engine.stop();
    if (_engine.start(engineConfigToEngine(config)).isOk) {
      _stopReconnectPolling();
    }
  }

  /// Whether every pinned device id in [config] is present in [devices]. An
  /// empty id (system default) is always considered present.
  bool _pinnedDevicesPresent(EngineConfig config, List<AudioDevice> devices) {
    bool present(String id, {required bool isInput}) =>
        id.isEmpty || devices.any((d) => d.isInput == isInput && d.id == id);
    return present(config.playbackDeviceId, isInput: false) &&
        present(config.captureDeviceId, isInput: true);
  }

  LooperState _project(EngineSnapshot s) => LooperState(
    transport: TransportState(
      isRunning: s.isRunning,
      masterLengthFrames: s.masterLengthFrames,
      masterPositionFrames: s.masterPositionFrames,
    ),
    tracks: [
      for (var i = 0; i < s.tracks.length; i++)
        Track(
          channel: i,
          state: s.tracks[i].state,
          volume: s.tracks[i].volume,
          muted: s.tracks[i].muted,
          lengthFrames: s.tracks[i].lengthFrames,
          playheadFrames: s.masterPositionFrames,
          rms: s.tracks[i].rms,
          peak: s.tracks[i].peak,
          undoDepth: s.tracks[i].undoDepth,
          redoDepth: s.tracks[i].redoDepth,
          multiple: s.tracks[i].multiple,
          inputMask: s.tracks[i].inputMask,
          outputMask: s.tracks[i].outputMask,
          lanes: [
            for (var l = 0; l < s.tracks[i].lanes.length; l++)
              Lane(
                inputChannel: s.tracks[i].lanes[l].inputChannel,
                outputMask: s.tracks[i].lanes[l].outputMask,
                volume: s.tracks[i].lanes[l].volume,
                muted: s.tracks[i].lanes[l].muted,
                lengthFrames: s.tracks[i].lanes[l].lengthFrames,
                rms: s.tracks[i].lanes[l].rms,
                peak: s.tracks[i].lanes[l].peak,
                effects: _laneEffects[(i, l)] ?? const [],
              ),
          ],
        ),
    ],
    status: EngineStatus(
      deviceName: _engine.deviceName,
      sampleRate: s.sampleRate,
      bufferFrames: s.bufferFrames,
      inputChannels: s.inputChannels,
      outputChannels: s.outputChannels,
      latencyState: latencyStateFromEngine(s.latencyState),
      measuredLatencyMs: s.measuredLatencyMs,
      xrunCount: s.xrunCount,
      isConnected: s.isRunning,
      devicePresent: s.devicePresent,
      excludedInputMask: s.excludedInputMask,
      recordOffsetFrames: s.recordOffsetFrames,
      fxAddedLatencyFrames: s.fxAddedLatencyFrames,
      activeBackend: audioBackendFromEngine(s.activeBackend),
    ),
    outputEnabledMask: s.outputEnabledMask,
  );

  /// Enumerates the host's audio devices (playback + capture) for the picker.
  List<AudioDevice> devices() =>
      _engine.enumerateDevices().map(audioDeviceFromEngine).toList();

  /// Enumerates the installed ASIO drivers (one duplex [AudioDevice] each) for
  /// the backend selector's driver picker. Empty off Windows / the default
  /// build. Must not be called while running on the ASIO backend (the cubit
  /// enforces this — see the re-entrancy contract on
  /// [AudioEngine.enumerateAsioDrivers]).
  List<AudioDevice> asioDrivers() =>
      _engine.enumerateAsioDrivers().map(audioDeviceFromEngine).toList();

  /// Opens the audio device and starts processing.
  EngineResult startEngine(EngineConfig config) {
    final result = _engine.start(engineConfigToEngine(config));
    if (result.isOk) {
      _lastEngineConfig = config;
      _intendRunning = true;
      // A fresh start resets the engine's quantize flag and monitor masks;
      // re-apply the desired state so it survives device changes / reconnects.
      _engine.setQuantize(enabled: _quantize);
      _trackQuantize.forEach(
        (channel, enabled) =>
            _engine.setTrackQuantize(channel: channel, enabled: enabled),
      );
      _engine
        ..setRecDub(enabled: _recDub)
        ..setAutoRecord(enabled: _autoRecord)
        ..setDefaultMultiple(multiple: _defaultMultiple)
        ..setMasterGain(_masterGain)
        // Master peak limiter on by default: a fresh start resets it to off, so
        // re-assert it here (like the rest) to guard the summed output against
        // driver clipping. No UI yet — this is a safety default.
        ..setLimiter(enabled: true);
      _trackMultiple.forEach(
        (channel, multiple) =>
            _engine.setTrackMultiple(channel: channel, multiple: multiple),
      );
      // Re-apply per-lane state: counts first (so added lanes are allocated),
      // then routing / mix / effects per lane.
      _laneCount.forEach(
        (channel, count) =>
            _engine.setLaneCount(channel: channel, count: count),
      );
      _laneInput.forEach(
        (key, inputChannel) => _engine.setLaneInput(
          channel: key.$1,
          lane: key.$2,
          inputChannel: inputChannel,
        ),
      );
      _laneOutput.forEach(
        (key, mask) =>
            _engine.setLaneOutput(channel: key.$1, lane: key.$2, mask: mask),
      );
      _laneVolume.forEach(
        (key, volume) =>
            _engine.setLaneVolume(volume, channel: key.$1, lane: key.$2),
      );
      _laneMute.forEach(
        (key, muted) =>
            _engine.setLaneMute(muted: muted, channel: key.$1, lane: key.$2),
      );
      for (final key in _laneEffects.keys) {
        _applyLaneEffects(key.$1, key.$2);
      }
      // Re-apply per-input live monitors: enable first, then the single chain's
      // routing / mix / effects.
      _monitorInputEnabled.forEach(
        (input, enabled) =>
            _engine.setMonitorInputEnabled(input: input, enabled: enabled),
      );
      _monitorOutput.forEach(
        (input, mask) =>
            _engine.setMonitorInputOutput(input: input, mask: mask),
      );
      _monitorVolume.forEach(
        (input, volume) =>
            _engine.setMonitorInputVolume(input: input, volume: volume),
      );
      _monitorMute.forEach(
        (input, muted) =>
            _engine.setMonitorInputMute(input: input, muted: muted),
      );
      _monitorEffects.keys.toList().forEach(_applyMonitorEffects);
      // Re-apply the structural output gate. A fresh start enables every
      // output, so only the stored OFF entries need re-asserting (default-on).
      _outputEnabled.forEach(
        (output, enabled) =>
            _engine.setOutputEnabled(output: output, enabled: enabled),
      );
    }
    return result;
  }

  /// Closes the audio device. A deliberate stop also cancels any in-flight
  /// reconnect supervision so the engine is not reopened behind the user.
  EngineResult stopEngine() {
    _intendRunning = false;
    _stopReconnectPolling();
    // The engine tears down all plugin slots on stop; drop our stale handles so
    // a later param set doesn't address a freed slot.
    _laneSlots.clear();
    _monitorSlots.clear();
    return _engine.stop();
  }

  /// Detects a cable-free loopback capture path for auto-measuring latency.
  LoopbackInfo detectLoopback() =>
      loopbackInfoFromEngine(_engine.detectLoopback());

  /// Triggers a loopback round-trip latency measurement.
  EngineResult measureLatency() => _engine.measureLatency();

  /// Advances track [channel]: record / finalize loop / toggle overdub.
  ///
  /// When the track is leaving EMPTY (a fresh capture), the input's live
  /// monitor chain is snapshot-copied onto each recording lane (mirroring the
  /// engine's own copy-on-record) so the take's remembered FX matches what was
  /// monitored. The copy is by value, so editing the input chain afterwards
  /// never alters the take (D3).
  EngineResult record({int channel = 0}) {
    final snapshot = _engine.snapshot();
    if (channel >= 0 &&
        channel < snapshot.tracks.length &&
        snapshot.tracks[channel].state == TrackState.empty) {
      _snapshotMonitorChainsOntoLanes(channel);
    }
    return _engine.record(channel: channel);
  }

  /// Copies each active lane's recorded-input monitor chain onto the lane's own
  /// remembered effect chain (by value). Mirrors the engine snapshot-on-
  /// record so [LooperState] / persistence reflect the take's FX. A lane with no
  /// monitorable input gets a cleared chain.
  void _snapshotMonitorChainsOntoLanes(int channel) {
    final count = _laneCount[channel] ?? 1;
    for (var lane = 0; lane < count; lane++) {
      final input = _laneInput[(channel, lane)] ?? lane;
      final chain = (input >= 0 && input < kMaxInputs)
          ? _monitorEffects[input]
          : null;
      if (chain == null || chain.isEmpty) {
        _laneEffects.remove((channel, lane));
      } else {
        _laneEffects[(channel, lane)] = List<TrackEffect>.of(chain);
      }
    }
  }

  /// Halts track [channel]'s playback (retaining the buffer).
  EngineResult stopTrack({int channel = 0}) =>
      _engine.stopTrack(channel: channel);

  /// Resumes playback of track [channel].
  EngineResult play({int channel = 0}) => _engine.play(channel: channel);

  /// Erases track [channel] (resets the master if all tracks empty).
  EngineResult clear({int channel = 0}) => _engine.clear(channel: channel);

  /// Removes the most recent overdub layer on track [channel].
  EngineResult undo({int channel = 0}) => _engine.undo(channel: channel);

  /// Re-applies the most recently undone overdub layer on track [channel].
  EngineResult redo({int channel = 0}) => _engine.redo(channel: channel);

  /// Sets track [channel]'s playback gain (`0..1`). Convenience for lane 0.
  EngineResult setVolume(double volume, {int channel = 0}) =>
      setLaneVolume(volume, channel: channel, lane: 0);

  /// Mutes or unmutes track [channel]. Convenience for lane 0.
  EngineResult setMute({required bool muted, int channel = 0}) =>
      setLaneMute(muted: muted, channel: channel, lane: 0);

  /// Routes track [channel]'s lane 0 record source to the input channels in
  /// [mask]. A lane records a single input, so the lowest set bit is used
  /// (`0` => record nothing); the full per-lane assignment UI lands in a later
  /// PR. Convenience for lane 0.
  EngineResult setInputMask({required int channel, required int mask}) =>
      setLaneInput(
        channel: channel,
        lane: 0,
        inputChannel: maskToInputChannel(mask),
      );

  /// Routes track [channel]'s lane 0 playback to the output channels in [mask].
  /// Convenience for lane 0.
  EngineResult setOutputMask({required int channel, required int mask}) =>
      setLaneOutput(channel: channel, lane: 0, mask: mask);

  /// Sets track [channel]'s active lane count (`>= 1`), lazily allocating the
  /// buffers for any newly added lanes. Remembered and re-applied on every
  /// (re)start; takes effect immediately only while running.
  EngineResult setLaneCount({required int channel, required int count}) {
    if (count <= 1) {
      _laneCount.remove(channel);
    } else {
      _laneCount[channel] = count;
    }
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setLaneCount(channel: channel, count: count);
  }

  /// Track [channel]'s remembered active lane count (`1` if unset).
  int laneCount(int channel) => _laneCount[channel] ?? 1;

  /// Lane [lane] of track [channel] records hardware input [inputChannel]
  /// (`-1` = none) into its own clean buffer. Remembered and re-applied on
  /// every (re)start.
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    _laneInput[(channel, lane)] = inputChannel;
    return _engine.setLaneInput(
      channel: channel,
      lane: lane,
      inputChannel: inputChannel,
    );
  }

  /// Routes lane [lane] of track [channel]'s playback to the output channels in
  /// [mask]. Remembered and re-applied on every (re)start.
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    _laneOutput[(channel, lane)] = mask;
    return _engine.setLaneOutput(channel: channel, lane: lane, mask: mask);
  }

  /// Sets lane [lane] of track [channel]'s playback gain (`0..1`). Remembered
  /// and re-applied on every (re)start.
  EngineResult setLaneVolume(
    double volume, {
    required int channel,
    required int lane,
  }) {
    _laneVolume[(channel, lane)] = volume;
    return _engine.setLaneVolume(volume, channel: channel, lane: lane);
  }

  /// Mutes or unmutes lane [lane] of track [channel]. Remembered and re-applied
  /// on every (re)start.
  EngineResult setLaneMute({
    required bool muted,
    required int channel,
    required int lane,
  }) {
    _laneMute[(channel, lane)] = muted;
    return _engine.setLaneMute(muted: muted, channel: channel, lane: lane);
  }

  /// Enables or disables live monitoring of hardware [input]. The input-level
  /// gate; per-lane routing / mix / effects drive each lane. The monitored
  /// signal is never recorded. Remembered and re-applied on every (re)start;
  /// takes effect immediately only while running.
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) {
    _monitorInputEnabled[input] = enabled;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMonitorInputEnabled(input: input, enabled: enabled);
  }

  /// Routes monitor [input]'s chain to the output channels in [mask].
  /// Remembered and re-applied on every (re)start; takes effect immediately
  /// only while running.
  EngineResult setMonitorOutput({required int input, required int mask}) {
    _monitorOutput[input] = mask;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMonitorInputOutput(input: input, mask: mask);
  }

  /// Sets monitor [input]'s output gain ([volume], `0..1`). Remembered and
  /// re-applied on every (re)start; takes effect immediately while running.
  EngineResult setMonitorVolume({required int input, required double volume}) {
    _monitorVolume[input] = volume;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMonitorInputVolume(input: input, volume: volume);
  }

  /// Mutes or unmutes monitor [input]. Remembered and re-applied on every
  /// (re)start; takes effect immediately only while running.
  EngineResult setMonitorMute({required int input, required bool muted}) {
    _monitorMute[input] = muted;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMonitorInputMute(input: input, muted: muted);
  }

  /// Turns hardware [output] on/off as a routing target (the structural output
  /// gate). A disabled output is removed from the mix while its lane/monitor
  /// route masks are preserved — re-enabling restores them. Default-on: only
  /// off entries are remembered, and they are re-applied on every (re)start.
  EngineResult setOutputEnabled({required int output, required bool enabled}) {
    if (enabled) {
      _outputEnabled.remove(output); // absence == enabled (default-on)
    } else {
      _outputEnabled[output] = false;
    }
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setOutputEnabled(output: output, enabled: enabled);
  }

  /// Whether hardware [output] is currently enabled (a routing target). Reads
  /// the remembered gate (absence == enabled).
  bool outputEnabled(int output) => _outputEnabled[output] ?? true;

  /// Reads the loop waveform (peaks indexed by loop position, `0..1`) of the
  /// mixed output for the visualizer.
  Float32List readWaveform() => _engine.readVisual();

  /// Reads track [channel]'s loop waveform for a per-track thumbnail.
  Float32List readTrackWaveform(int channel) =>
      _engine.readTrackVisual(channel);

  /// Sets the record-offset latency compensation in frames.
  EngineResult setRecordOffset(int frames) => _engine.setRecordOffset(frames);

  /// Overrides quantize for track [channel]: `null` inherits the global
  /// default, `false` forces it off, `true` forces it on. Remembered and
  /// re-applied on every (re)start.
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) {
    if (enabled == null) {
      _trackQuantize.remove(channel);
    } else {
      _trackQuantize[channel] = enabled;
    }
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setTrackQuantize(channel: channel, enabled: enabled);
  }

  /// Fixes track [channel]'s loop length to [multiple] base loops (`0` = auto).
  /// Remembered and re-applied on every (re)start.
  EngineResult setTrackMultiple({required int channel, required int multiple}) {
    if (multiple <= 0) {
      _trackMultiple.remove(channel);
    } else {
      _trackMultiple[channel] = multiple;
    }
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setTrackMultiple(
      channel: channel,
      multiple: multiple <= 0 ? 0 : multiple,
    );
  }

  /// Replaces lane [lane] of track [channel]'s effect chain with [effects]
  /// (clamped to [kTrackEffectMax]). Remembered and re-applied on every
  /// (re)start. Use this for structural edits (add / remove / reorder / type);
  /// it resets the affected entries' DSP state. For a live parameter tweak use
  /// [setLaneEffectParam], which does not.
  EngineResult setLaneEffects({
    required int channel,
    required int lane,
    required List<TrackEffect> effects,
  }) {
    final clamped = effects.length > kTrackEffectMax
        ? effects.sublist(0, kTrackEffectMax)
        : List<TrackEffect>.of(effects);
    if (clamped.isEmpty) {
      _laneEffects.remove((channel, lane));
    } else {
      _laneEffects[(channel, lane)] = clamped;
    }
    _reproject();
    if (!_intendRunning) return EngineResult.ok;
    return _applyLaneEffects(channel, lane);
  }

  /// Sets parameter [param] of chain entry [index] on lane [lane] of track
  /// [channel] to [value] (`0..1`) without resetting DSP state. Remembered and
  /// re-applied on (re)start. No-op if [index] is out of range for the
  /// remembered chain.
  EngineResult setLaneEffectParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    // Built-in params only — a plugin's parameter surface arrives in part 5.
    if (fx is! BuiltInEffect) return EngineResult.invalid;
    if (param < 0 || param >= fx.params.length) return EngineResult.invalid;
    final params = List<double>.of(fx.params)..[param] = value;
    // Replace the stored list with a fresh instance rather than mutating it in
    // place: `_project` puts this list into the emitted `LooperState` by
    // reference, so an in-place edit would also mutate the last-emitted state,
    // and the poll's `next == _last` check would then suppress the update.
    _laneEffects[(channel, lane)] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(params: params);
    _reproject();
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setLaneFxParam(
      channel: channel,
      lane: lane,
      index: index,
      param: param,
      value: value,
    );
  }

  /// Sets hosted-plugin parameter [paramId] of lane [lane]'s chain entry
  /// [index] to the plain [value], routing it to the loaded plugin through the
  /// RT param queue. The value is remembered on the [PluginEffect] so it
  /// persists and re-applies when the plugin reloads. Returns [EngineResult
  /// .invalid] if the entry is not a plugin, or the running plugin has no live
  /// slot (e.g. its load failed).
  EngineResult setLanePluginParam({
    required int channel,
    required int lane,
    required int index,
    required int paramId,
    required double value,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    final values = Map<int, double>.of(fx.paramValues)..[paramId] = value;
    _laneEffects[(channel, lane)] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(paramValues: values);
    _reproject();
    if (!_intendRunning) return EngineResult.ok;
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return EngineResult.invalid;
    return _engine.pluginParamSet(handle, paramId, value);
  }

  /// Lane [lane] of track [channel]'s remembered effect chain (empty if none),
  /// in processing order.
  List<TrackEffect> laneEffects(int channel, int lane) =>
      List<TrackEffect>.unmodifiable(_laneEffects[(channel, lane)] ?? const []);

  /// Pushes lane [lane] of track [channel]'s remembered chain to the engine:
  /// each entry's type (which seeds default params), then its parameter values,
  /// then the active count. Called on (re)start and after a structural edit.
  EngineResult _applyLaneEffects(int channel, int lane) {
    final effects = _laneEffects[(channel, lane)] ?? const <TrackEffect>[];
    // Drop any slot handles from a previous apply of this lane before reloading
    // — the engine reseats the chain, so old handles no longer address it.
    _laneSlots.removeWhere((key, _) => key.$1 == channel && key.$2 == lane);
    final next = <TrackEffect>[];
    var mutated = false;
    for (var i = 0; i < effects.length; i++) {
      final fx = effects[i];
      if (fx is PluginEffect) {
        // Load the plugin through the slot ABI, then enumerate its parameter
        // surface and replay any persisted values through the RT queue.
        final handle = _engine.setLanePlugin(
          channel: channel,
          lane: lane,
          index: i,
          pluginId: fx.ref.id,
        );
        final loaded = _bindPluginSlot(handle, fx);
        if (handle != null) _laneSlots[(channel, lane, i)] = handle;
        if (loaded != fx) mutated = true;
        next.add(loaded);
        continue;
      }
      next.add(fx);
      if (fx is! BuiltInEffect) continue;
      _engine.setLaneFx(
        channel: channel,
        lane: lane,
        index: i,
        type: trackEffectTypeToEngine(fx.type),
      );
      for (var p = 0; p < fx.params.length; p++) {
        _engine.setLaneFxParam(
          channel: channel,
          lane: lane,
          index: i,
          param: p,
          value: fx.params[p],
        );
      }
    }
    // Store the params-enriched chain so the projected state carries the live
    // knob metadata, then re-emit (only when something actually changed).
    if (mutated) {
      _laneEffects[(channel, lane)] = next;
      _reproject();
    }
    return _engine.setLaneFxCount(
      channel: channel,
      lane: lane,
      count: effects.length,
    );
  }

  /// Reconciles a freshly-loaded plugin [handle] with its chain entry [fx]:
  /// enumerates the plugin's live parameter surface into [PluginEffect.params]
  /// and replays each persisted value in [PluginEffect.paramValues] through the
  /// RT param queue. A `null` handle (load failed / engine stopped) clears the
  /// stale metadata so the card renders the unresolved state.
  PluginEffect _bindPluginSlot(PluginSlotHandle? handle, PluginEffect fx) {
    if (handle == null) {
      return fx.params.isEmpty ? fx : fx.copyWith(params: const []);
    }
    final infos = _engine
        .pluginParamInfos(handle)
        .map(pluginParamInfoFromEngine)
        .toList();
    for (final entry in fx.paramValues.entries) {
      _engine.pluginParamSet(handle, entry.key, entry.value);
    }
    return fx.copyWith(params: infos);
  }

  /// Replaces track [channel]'s lane 0 effect chain. Convenience for lane 0.
  EngineResult setTrackEffects({
    required int channel,
    required List<TrackEffect> effects,
  }) => setLaneEffects(channel: channel, lane: 0, effects: effects);

  /// Sets a parameter on track [channel]'s lane 0 chain (lane-0 convenience).
  EngineResult setTrackEffectParam({
    required int channel,
    required int index,
    required int param,
    required double value,
  }) => setLaneEffectParam(
    channel: channel,
    lane: 0,
    index: index,
    param: param,
    value: value,
  );

  /// Track [channel]'s lane 0 remembered effect chain. Convenience for lane 0.
  List<TrackEffect> trackEffects(int channel) => laneEffects(channel, 0);

  /// Replaces monitor [input]'s effect chain with [effects] (clamped to
  /// [kTrackEffectMax]). An empty chain is the clean (dry) path. Remembered and
  /// re-applied on every (re)start; this is the chain snapshot-copied onto a
  /// lane on record. A structural edit resets the affected entries' DSP state.
  /// For a live parameter tweak use [setMonitorEffectParam].
  EngineResult setMonitorEffects({
    required int input,
    required List<TrackEffect> effects,
  }) {
    final clamped = effects.length > kTrackEffectMax
        ? effects.sublist(0, kTrackEffectMax)
        : List<TrackEffect>.of(effects);
    if (clamped.isEmpty) {
      _monitorEffects.remove(input);
    } else {
      _monitorEffects[input] = clamped;
    }
    if (!_intendRunning) return EngineResult.ok;
    return _applyMonitorEffects(input);
  }

  /// Sets parameter [param] of monitor [input]'s chain entry [index] to [value]
  /// (`0..1`) without resetting DSP state. Remembered and re-applied on
  /// (re)start. No-op if [index] is out of range for the remembered chain.
  EngineResult setMonitorEffectParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    // Built-in params only — a plugin's parameter surface arrives in part 5.
    if (fx is! BuiltInEffect) return EngineResult.invalid;
    if (param < 0 || param >= fx.params.length) return EngineResult.invalid;
    final params = List<double>.of(fx.params)..[param] = value;
    // Replace with a fresh list rather than mutating in place — the same
    // invariant as `setLaneEffectParam`. No `_reproject()` here: monitor
    // chains are not part of the projected `LooperState` (the MonitorCubit
    // owns them and emits optimistically), so there is nothing to re-emit.
    _monitorEffects[input] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(params: params);
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMonitorInputFxParam(
      input: input,
      index: index,
      param: param,
      value: value,
    );
  }

  /// Sets hosted-plugin parameter [paramId] of monitor [input]'s chain entry
  /// [index] to the plain [value], routing it through the RT param queue and
  /// remembering it on the [PluginEffect]. No `_reproject()`: monitor chains
  /// are not part of the projected `LooperState`. Returns
  /// [EngineResult.invalid] if the entry is not a plugin, or its slot is gone.
  EngineResult setMonitorPluginParam({
    required int input,
    required int index,
    required int paramId,
    required double value,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    final values = Map<int, double>.of(fx.paramValues)..[paramId] = value;
    _monitorEffects[input] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(paramValues: values);
    if (!_intendRunning) return EngineResult.ok;
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return EngineResult.invalid;
    return _engine.pluginParamSet(handle, paramId, value);
  }

  /// Monitor [input]'s remembered effect chain (empty if none), in processing
  /// order.
  List<TrackEffect> monitorEffects(int input) =>
      List<TrackEffect>.unmodifiable(_monitorEffects[input] ?? const []);

  /// Pushes monitor [input]'s remembered chain to the engine: each entry's type
  /// (which seeds default params), then its parameter values, then the active
  /// count. Called on (re)start and after a structural edit.
  EngineResult _applyMonitorEffects(int input) {
    final effects = _monitorEffects[input] ?? const <TrackEffect>[];
    _monitorSlots.removeWhere((key, _) => key.$1 == input);
    final next = <TrackEffect>[];
    var mutated = false;
    for (var i = 0; i < effects.length; i++) {
      final fx = effects[i];
      if (fx is PluginEffect) {
        final handle = _engine.setMonitorPlugin(
          input: input,
          index: i,
          pluginId: fx.ref.id,
        );
        final loaded = _bindPluginSlot(handle, fx);
        if (handle != null) _monitorSlots[(input, i)] = handle;
        if (loaded != fx) mutated = true;
        next.add(loaded);
        continue;
      }
      next.add(fx);
      if (fx is! BuiltInEffect) continue;
      _engine.setMonitorInputFx(
        input: input,
        index: i,
        type: trackEffectTypeToEngine(fx.type),
      );
      for (var p = 0; p < fx.params.length; p++) {
        _engine.setMonitorInputFxParam(
          input: input,
          index: i,
          param: p,
          value: fx.params[p],
        );
      }
    }
    // Monitor chains are not part of the projected `LooperState` (the
    // MonitorCubit owns and emits them), so we only refresh the remembered
    // chain with the live param metadata — no `_reproject()`.
    if (mutated) _monitorEffects[input] = next;
    return _engine.setMonitorInputFxCount(input: input, count: effects.length);
  }

  /// Sets the global default loop length for inheriting tracks (`0` = auto).
  /// Remembered and re-applied on every (re)start.
  EngineResult setDefaultMultiple({required int multiple}) {
    _defaultMultiple = multiple < 0 ? 0 : multiple;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setDefaultMultiple(multiple: _defaultMultiple);
  }

  /// Sets the global rec/dub second-press mode. Remembered and re-applied on
  /// every (re)start.
  EngineResult setRecDub({required bool enabled}) {
    _recDub = enabled;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setRecDub(enabled: enabled);
  }

  /// Sets the global master output gain (`0..1`, clamped by the engine).
  /// Remembered and re-applied on every (re)start so it survives device changes
  /// and reconnects.
  EngineResult setMasterGain(double gain) {
    _masterGain = gain.clamp(0.0, 1.0);
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMasterGain(_masterGain);
  }

  /// Enables global sound-activated recording. Remembered and re-applied on
  /// every (re)start.
  EngineResult setAutoRecord({required bool enabled}) {
    _autoRecord = enabled;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setAutoRecord(enabled: enabled);
  }

  /// Enables or disables quantized recording (captures snap to the loop grid).
  /// The value is remembered and re-applied on every engine (re)start — a fresh
  /// start (device change, reconnect) resets the engine's flag — so it survives
  /// restarts. Applied to the live engine only while running.
  EngineResult setQuantize({required bool enabled}) {
    _quantize = enabled;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setQuantize(enabled: enabled);
  }

  /// Releases the repository and the underlying engine.
  Future<void> dispose() async {
    await _stopPollingAndClose();
    _engine.dispose();
  }

  Future<void> _stopPollingAndClose() async {
    _stopPolling();
    _stopReconnectPolling();
    await _controller.close();
  }
}
