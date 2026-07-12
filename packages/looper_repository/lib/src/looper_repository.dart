import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:looper_repository/src/models/audio_config.dart';
import 'package:looper_repository/src/models/engine_status.dart';
import 'package:looper_repository/src/models/input_monitor.dart';
import 'package:looper_repository/src/models/lane.dart';
import 'package:looper_repository/src/models/looper_state.dart';
import 'package:looper_repository/src/models/plugin_descriptor.dart'
    show PluginDescriptor, PluginParamInfo, pluginParamInfoFromEngine;
import 'package:looper_repository/src/models/session_rig.dart';
import 'package:looper_repository/src/models/track.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:looper_repository/src/models/transport_state.dart';
import 'package:looper_repository/src/plugin_catalog.dart';
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
        PluginDescriptor,
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

  /// Fired synchronously whenever the repository mutates a lane's effect chain
  /// on its own initiative — today the record-time snapshot-copy of a monitor
  /// chain onto the recording lanes (F3). The bloc subscribes and persists the
  /// resulting chain, so a take's remembered FX survive a restart.
  ///
  /// UI-driven structural chain edits do NOT fire this: the bloc already
  /// persists those at the edit, and the bloc is the single settings writer for
  /// chains, so double-writing is avoided. One listener (the looper bloc); a
  /// later subscriber replaces it.
  void Function(int channel, int lane)? onLaneChainChanged;

  /// The plugin scan catalog over this repository's engine (lazily created so
  /// the scan thread only spins up when something asks for plugins). The
  /// `appVersion` cache key is a placeholder until part 7 persists the cache.
  late final PluginCatalog pluginCatalog = PluginCatalog(
    engine: _engine,
    appVersion: '0.0.0',
  );
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

  /// Single-flight scan backing [_recoverUnavailablePlugins]: started the first
  /// time a restored chain surfaces an unavailable plugin, then reused so the
  /// plugin dirs are scanned at most once per session.
  Future<List<PluginDescriptor>>? _restoredPluginScan;

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
    // Release the dead device with a RAW stop (not stopEngine(), which would
    // clear _intendRunning and disarm this supervisor), then reopen through
    // startEngine — NOT a raw _engine.start — so the remembered rig (lanes,
    // monitors, mix, effects, output gate, hosted plugins) is re-applied to the
    // freshly-configured engine. A raw start comes back at engine defaults,
    // silently dropping the live rig on every reconnect.
    _engine.stop();
    if (startEngine(config).isOk) {
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
          layerInFlight: s.tracks[i].layerInFlight,
          pending: s.tracks[i].pending,
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
      // Restored plugins load by id through the native scan cache, which is
      // empty on a cold start — so the apply above leaves them unavailable.
      // Most chains are restored AFTER this call (by the cubits, through
      // setLaneEffects/setMonitorEffects), so the same recovery also fires from
      // there; this call covers a mid-session reconnect where the chains are
      // already present.
      _recoverUnavailablePlugins();
    }
    return result;
  }

  /// Whether [effects] holds a hosted plugin that failed to load (its id was
  /// not in the scan cache when the chain was applied).
  static bool _hasUnavailablePlugin(Iterable<TrackEffect> effects) =>
      effects.any((e) => e is PluginEffect && e.unavailable);

  /// Recovers plugins that failed to load because the engine's in-process scan
  /// cache was empty when their chain was applied.
  ///
  /// On a cold start nothing has scanned yet, and the saved chains are restored
  /// (by the cubits, through [setLaneEffects]/[setMonitorEffects]) *after*
  /// [startEngine] — so a one-shot scan at start would run before any chain
  /// exists and miss them, leaving the entries stuck as unavailable
  /// placeholders until the user relinks by hand. Instead, whenever an applied
  /// chain surfaces an unavailable plugin, kick a single catalog scan and
  /// re-apply the affected chains once it lands, so the plugins load (resolving
  /// their display names too) on their own.
  ///
  /// While that recovery scan is in flight the affected entries are flipped to
  /// the transient "loading…" state (F5), so the UI shows a spinner rather than
  /// a scary "unavailable + relink" during the brief auto-recovery window; the
  /// re-apply then resolves them, or restores genuine unavailability if the
  /// plugin is still missing. A no-op when nothing is unavailable.
  void _recoverUnavailablePlugins() {
    final laneKeys = [
      for (final e in _laneEffects.entries)
        if (_hasUnavailablePlugin(e.value)) e.key,
    ];
    final monitorKeys = [
      for (final e in _monitorEffects.entries)
        if (_hasUnavailablePlugin(e.value)) e.key,
    ];
    if (laneKeys.isEmpty && monitorKeys.isEmpty) return;
    // A populated catalog means a scan already ran this session: the chains
    // were applied against a warm cache, so a plugin still unavailable is
    // genuinely missing/unsupported and rescanning cannot change that.
    if (pluginCatalog.descriptors.isNotEmpty) return;
    _markUnavailablePluginsLoading(laneKeys, monitorKeys);
    final scan = _restoredPluginScan ??= pluginCatalog.scan();
    unawaited(
      scan.then((_) {
        if (!_intendRunning) return; // stopped while scanning
        for (final key in laneKeys) {
          _applyLaneEffects(key.$1, key.$2);
        }
        monitorKeys.forEach(_applyMonitorEffects);
      }),
    );
  }

  /// Flips the unavailable plugin entries of the given lane / monitor chains to
  /// the transient loading state (F5) while [_recoverUnavailablePlugins]'s scan
  /// runs. Lane chains re-project so the UI updates; monitor chains update the
  /// cache (the MonitorCubit re-reads it), mirroring how the scan-landed
  /// re-apply reaches each.
  void _markUnavailablePluginsLoading(
    List<(int, int)> laneKeys,
    List<int> monitorKeys,
  ) {
    PluginEffect toLoading(PluginEffect fx) =>
        fx.copyWith(loading: true, unavailable: false, unsupported: false);
    for (final key in laneKeys) {
      final effects = _laneEffects[key];
      if (effects == null) continue;
      _laneEffects[key] = [
        for (final fx in effects)
          if (fx is PluginEffect && fx.unavailable) toLoading(fx) else fx,
      ];
    }
    for (final input in monitorKeys) {
      final effects = _monitorEffects[input];
      if (effects == null) continue;
      _monitorEffects[input] = [
        for (final fx in effects)
          if (fx is PluginEffect && fx.unavailable) toLoading(fx) else fx,
      ];
    }
    if (laneKeys.isNotEmpty) _reproject();
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
  /// monitor chain is snapshot-copied onto each recording lane and pushed to
  /// the engine, so the take's remembered FX matches what was monitored. The
  /// repository is the sole record-time snapshot authority: it computes the
  /// snapshot from the synchronously-correct `_monitorEffects` cache (never
  /// from ring-deferred engine state), so there is no drain-timing race. The
  /// copy is by value, so editing the input chain afterwards never alters the
  /// take (D3).
  EngineResult record({int channel = 0}) {
    final snapshot = _engine.snapshot();
    final state = channel >= 0 && channel < snapshot.tracks.length
        ? snapshot.tracks[channel].state
        : null;
    if (state == TrackState.empty) {
      _snapshotMonitorChainsOntoLanes(channel);
      // The engine unmutes every lane on a record-from-empty (a fresh take is
      // always audible); forget the remembered mutes too, or a device
      // reconnect would replay them and silence the take mid-performance.
      _forgetLaneMutes(channel);
    } else if (state == TrackState.playing) {
      // An overdub onto a live loop must be audible too — you're recording into
      // it. Unlike record-from-empty the engine does NOT auto-unmute here, so
      // unmute every lane explicitly; forget the remembered mutes for the same
      // reconnect-replay reason as above.
      _forgetLaneMutes(channel);
      for (var lane = 0; lane < laneCount(channel); lane++) {
        _engine.setLaneMute(muted: false, channel: channel, lane: lane);
      }
    }
    return _engine.record(channel: channel);
  }

  /// Drops the remembered per-lane mutes for [channel] — used when the engine
  /// itself force-unmutes (clear, record-from-empty, redo-from-empty), so the
  /// restart replay can't resurrect a stale mute over an audible track.
  void _forgetLaneMutes(int channel) {
    _laneMute.removeWhere((key, _) => key.$1 == channel);
  }

  /// Copies each active lane's recorded-input monitor chain onto the lane's own
  /// remembered effect chain (by value) AND pushes it to the engine — the
  /// repository is the single record-time snapshot authority and the engine is
  /// a pure sink that holds only what the repo pushes (it no longer self-
  /// snapshots on record). Keeps [LooperState] / persistence / engine all
  /// deriving from the one owner. A lane with nothing monitored (no monitorable
  /// input, or a clean input chain) keeps its own chain — that dry path bails
  /// before any push, so the lane's engine chain is left untouched. A *non-
  /// empty* monitored chain always overwrites the lane (D2 — the take sounds
  /// like what was monitored), even if plugin captures reduce it to empty; that
  /// overwrite is pushed too, so cache and engine stay equal.
  void _snapshotMonitorChainsOntoLanes(int channel) {
    // Iterate the repo's own lane config (`_laneCount` / `_laneInput`). The repo
    // is the single writer of both — every `setLaneCount` / `setLaneInput`
    // updates the cache and the engine together — so this targets exactly the
    // track's active lanes and their recorded inputs (must-verify #3), with no
    // read of ring-deferred engine state.
    final count = _laneCount[channel] ?? 1;
    for (var lane = 0; lane < count; lane++) {
      final input = _laneInput[(channel, lane)] ?? lane;
      final chain = (input >= 0 && input < kMaxInputs)
          ? _monitorEffects[input]
          : null;
      if (chain == null || chain.isEmpty) continue;
      // D-P1: a plugin in the monitor chain can't be value-copied — capture
      // its live opaque state so the lane re-instantiates a frozen instance
      // from that exact state on playback. The recorded audio is dry either
      // way, so a capture failure just drops the entry (bypassed) without
      // affecting the take.
      final snapshot = <TrackEffect>[];
      for (var i = 0; i < chain.length; i++) {
        final captured = _capturePluginForLane(chain[i], input, i);
        if (captured != null) snapshot.add(captured);
      }
      if (snapshot.isEmpty) {
        // Every entry of a non-empty monitored chain failed to capture (all
        // plugins, all bypassed): the monitored chain still overwrites the lane
        // (D2), reducing it to empty. Push that too (below) so a stale
        // staged/persisted engine chain can't outlive it and diverge.
        _laneEffects.remove((channel, lane));
      } else {
        _laneEffects[(channel, lane)] = snapshot;
      }
      // Push it to the engine's lane FX like any other lane edit (plugin
      // entries carry the frozen state captured above) — the pure-sink push
      // that lands the take's chain regardless of ring-drain timing.
      _applyLaneEffects(channel, lane);
      // The take's chain just changed under the repository's own hand — notify
      // so the bloc persists it (F3: without this, a restart replays the
      // pre-take chain from settings).
      onLaneChainChanged?.call(channel, lane);
    }
  }

  /// Snapshots one monitor chain entry onto a recording lane. Built-in effects
  /// copy by value; a plugin captures its live state blob from monitor slot
  /// `(input, index)`. Returns null when a plugin's capture fails (the entry is
  /// dropped → bypassed on playback; the dry take is unaffected).
  TrackEffect? _capturePluginForLane(TrackEffect fx, int input, int index) {
    if (fx is! PluginEffect) return fx;
    final handle = _monitorSlots[(input, index)];
    // Not loaded (engine settling): keep the entry + any prior persisted state.
    if (handle == null) return fx;
    final blob = _engine.pluginStateGet(handle);
    // Loaded but capture failed: drop the entry so the lane plays dry for it
    // (bypass). The recorded buffer is dry regardless, so the take is unharmed.
    if (blob.isEmpty) return null;
    return fx.copyWith(state: base64Encode(blob));
  }

  /// Halts track [channel]'s playback (retaining the buffer).
  EngineResult stopTrack({int channel = 0}) =>
      _engine.stopTrack(channel: channel);

  /// Resumes playback of track [channel].
  EngineResult play({int channel = 0}) => _engine.play(channel: channel);

  /// Erases track [channel] (resets the master if all tracks empty). The
  /// engine unmutes every lane; the remembered mutes are forgotten to match.
  EngineResult clear({int channel = 0}) {
    _forgetLaneMutes(channel);
    return _engine.clear(channel: channel);
  }

  /// Removes the most recent overdub layer on track [channel].
  EngineResult undo({int channel = 0}) => _engine.undo(channel: channel);

  /// Re-applies the most recently undone overdub layer on track [channel].
  /// A redo that resurrects an undone-to-empty track comes back unmuted
  /// engine-side; the remembered mutes are forgotten to match.
  EngineResult redo({int channel = 0}) {
    final snapshot = _engine.snapshot();
    if (channel >= 0 &&
        channel < snapshot.tracks.length &&
        snapshot.tracks[channel].state == TrackState.empty) {
      _forgetLaneMutes(channel);
    }
    return _engine.redo(channel: channel);
  }

  /// Applies a loaded session [rig] to the engine THROUGH this repository —
  /// the ONE session-apply path (F2). Every write lands in the remembered
  /// caches as well as the engine, so a device restart / reconnect replays the
  /// LOADED session by construction, never a pre-load cache.
  ///
  /// Order: clear every track via [clear] (which forgets remembered lane
  /// mutes), await the engine settling to empty, import the stems, commit the
  /// master loop, re-apply mix through the cached setters, then apply the
  /// rig's chains — explicitly resetting every remembered lane / monitor chain
  /// the rig does not define, so a previous session's leftovers can never
  /// sound under the loaded one.
  ///
  /// Clears are applied asynchronously on the audio thread;
  /// [clearPollInterval] / [clearPollAttempts] bound how long the settle wait
  /// polls (tests can shrink them). Throws [StateError] when the engine fails
  /// to clear or an import/commit is rejected.
  Future<void> applySession(
    SessionRig rig, {
    Duration clearPollInterval = const Duration(milliseconds: 8),
    int clearPollAttempts = 64,
  }) async {
    final trackCount = _engine.snapshot().tracks.length;
    for (var channel = 0; channel < trackCount; channel++) {
      clear(channel: channel);
    }
    // The session's mix replaces the remembered per-lane mix wholesale: purge
    // it all (not just the mutes [clear] forgot) so the restart replay carries
    // only the loaded values, then re-set from the rig below.
    _laneVolume.clear();
    _laneMute.clear();
    if (!await _awaitCleared(clearPollInterval, clearPollAttempts)) {
      throw StateError('engine did not clear before applying the session');
    }

    for (final track in rig.tracks) {
      // A clear posted just above may not be acked yet — the engine rejects an
      // import that races a pending state flip and expects a trivial retry. The
      // ack lands within a buffer or two, so cap the retry low (NOT the full
      // clear budget, which — times track count — could stall a load for
      // seconds on a genuinely bad stem before surfacing the error).
      final importRetries = clearPollAttempts < _maxImportAckRetries
          ? clearPollAttempts
          : _maxImportAckRetries;
      var result = _engine.importTrack(track.channel, track.pcm);
      for (
        var attempt = 0;
        !result.isOk && attempt < importRetries;
        attempt++
      ) {
        await Future<void>.delayed(clearPollInterval);
        result = _engine.importTrack(track.channel, track.pcm);
      }
      if (!result.isOk) {
        throw StateError(
          'failed to import track ${track.channel}: ${result.name}',
        );
      }
    }
    // An empty session (or a legacy save carrying a ghost grid with no
    // tracks) establishes no master: the cleared engine stays free to define
    // a fresh loop length.
    if (rig.tracks.isNotEmpty && rig.baseLengthFrames > 0) {
      final committed = _engine.commitSession(rig.baseLengthFrames);
      if (!committed.isOk) {
        throw StateError('failed to start the session: ${committed.name}');
      }
    }

    // Session stems are lane-0-only for now (full multi-lane stems are a
    // follow-up), so restore mix settings onto lane 0 — through the cached
    // setters, so `_laneVolume` / `_laneMute` stay truthful.
    for (final track in rig.tracks) {
      setLaneVolume(track.volume, channel: track.channel, lane: 0);
      setLaneMute(muted: track.muted, channel: track.channel, lane: 0);
    }

    // Chains: reset every remembered chain the rig does not define, then
    // apply the rig's. `setLaneEffects` / `setMonitorEffects` keep cache and
    // engine in lockstep (an empty chain pushes count 0 to the engine, wiping
    // any leftover engine-side chain a clear alone would have kept).
    for (final key in _laneEffects.keys.toList()) {
      if (!rig.laneEffects.containsKey(key)) {
        setLaneEffects(channel: key.$1, lane: key.$2, effects: const []);
      }
    }
    rig.laneEffects.forEach(
      (key, effects) =>
          setLaneEffects(channel: key.$1, lane: key.$2, effects: effects),
    );
    // Monitors: fully reset every remembered monitor the rig does not define —
    // not just its chain but its enable / routing / mix too, or an input
    // enabled under session A would keep monitoring under session B (the F2
    // leftover class). Reset to the disabled defaults, then apply the rig's.
    final definedMonitors = {for (final m in rig.monitors) m.input};
    // Snapshot the configured inputs before the reset loop mutates the maps.
    // Resetting a monitor already at the disabled default is a no-op, so the
    // default-omitting `allMonitors()` covers every input that needs clearing.
    final rememberedMonitors = allMonitors().keys.toList();
    for (final input in rememberedMonitors) {
      if (definedMonitors.contains(input)) continue;
      setMonitorInputEnabled(input: input, enabled: false);
      setMonitorOutput(input: input, mask: _defaultMonitorOutputMask);
      setMonitorVolume(input: input, volume: 1);
      setMonitorMute(input: input, muted: false);
      setMonitorEffects(input: input, effects: const []);
    }
    for (final monitor in rig.monitors) {
      setMonitorInputEnabled(input: monitor.input, enabled: monitor.enabled);
      setMonitorOutput(input: monitor.input, mask: monitor.outputMask);
      setMonitorVolume(input: monitor.input, volume: monitor.volume);
      setMonitorMute(input: monitor.input, muted: monitor.muted);
      setMonitorEffects(input: monitor.input, effects: monitor.effects);
    }
  }

  /// The default monitor output routing (the first stereo pair) an undefined
  /// monitor resets to on a session apply — matches [monitorOutput]'s default.
  static const int _defaultMonitorOutputMask = 0x3;

  /// The ceiling on how many times a session-import retries the posted-clear
  /// ack race (a few audio buffers). Bounds a genuinely-bad stem's failure so a
  /// load can't stall for seconds per track.
  static const int _maxImportAckRetries = 8;

  /// Polls until every track reports empty and the master is reset, returning
  /// whether the engine settled within [attempts].
  Future<bool> _awaitCleared(Duration interval, int attempts) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      final snapshot = _engine.snapshot();
      final cleared =
          snapshot.masterLengthFrames == 0 &&
          snapshot.tracks.every((t) => t.state == TrackState.empty);
      if (cleared) return true;
      await Future<void>.delayed(interval);
    }
    return false;
  }

  /// Every remembered non-empty lane effect chain, keyed by `(channel, lane)`
  /// — what a session save captures (the live rig is the truth being saved).
  Map<(int, int), List<TrackEffect>> allLaneEffects() => {
    for (final entry in _laneEffects.entries)
      entry.key: List<TrackEffect>.unmodifiable(entry.value),
  };

  /// Every **configured** live monitor, keyed by input — the union of all
  /// remembered monitor state (enable / routing / mix / effects), not just
  /// inputs that carry an FX chain. A monitor equal to the disabled default is
  /// omitted, so an absent input reads back as the disabled default on load.
  ///
  /// The single monitor-enumeration source of truth: a session save captures
  /// this (so a dry-but-enabled monitor round-trips), the MonitorCubit
  /// re-projects from it after a session load, and [applySession]'s reset walks
  /// its keys.
  Map<int, InputMonitor> allMonitors() {
    final inputs = <int>{
      ..._monitorInputEnabled.keys,
      ..._monitorOutput.keys,
      ..._monitorVolume.keys,
      ..._monitorMute.keys,
      ..._monitorEffects.keys,
    };
    final result = <int, InputMonitor>{};
    for (final input in inputs) {
      final monitor = InputMonitor(
        input: input,
        enabled: monitorEnabled(input),
        outputMask: monitorOutput(input),
        volume: monitorVolume(input),
        muted: monitorMuted(input),
        effects: monitorEffects(input),
      );
      // Skip inputs equal to the disabled default (no state worth persisting).
      if (monitor != InputMonitor(input: input)) result[input] = monitor;
    }
    return result;
  }

  /// Whether hardware [input]'s live monitor is enabled (remembered intent).
  bool monitorEnabled(int input) => _monitorInputEnabled[input] ?? false;

  /// Monitor [input]'s remembered output mask (the default stereo pair if
  /// never set).
  int monitorOutput(int input) =>
      _monitorOutput[input] ?? _defaultMonitorOutputMask;

  /// Monitor [input]'s remembered output gain (unity if never set).
  double monitorVolume(int input) => _monitorVolume[input] ?? 1;

  /// Whether monitor [input] is muted (remembered intent).
  bool monitorMuted(int input) => _monitorMute[input] ?? false;

  /// The fingerprint of lane [lane] of track [channel]'s CACHED chain, computed
  /// with the same folding as the engine's [AudioEngine.laneFxFingerprint], so
  /// the two can be compared for cache-vs-engine divergence (F6). An absent
  /// chain yields the empty-chain basis, matching an empty engine lane.
  int laneChainFingerprint(int channel, int lane) =>
      trackChainFingerprint(_laneEffects[(channel, lane)] ?? const []);

  /// The fingerprint of monitor [input]'s CACHED chain (see
  /// [laneChainFingerprint]).
  int monitorChainFingerprint(int input) =>
      trackChainFingerprint(_monitorEffects[input] ?? const []);

  /// Sets track [channel]'s playback gain (`0..1`) on **every lane of it**. A
  /// track-level volume is a whole-track control, so a multi-lane track scales
  /// all its lanes together, not just lane 0. Returns the last failing lane's
  /// result, or [EngineResult.ok] if all lanes succeed.
  EngineResult setVolume(double volume, {int channel = 0}) {
    var result = EngineResult.ok;
    for (var lane = 0; lane < laneCount(channel); lane++) {
      final r = setLaneVolume(volume, channel: channel, lane: lane);
      if (r != EngineResult.ok) result = r;
    }
    return result;
  }

  /// Mutes or unmutes track [channel] — **every lane of it**. A track-level
  /// mute is a whole-track control, so a multi-lane track silences (or
  /// restores) all its lanes, not just lane 0. Returns the last failing lane's
  /// result, or [EngineResult.ok] if all lanes succeed.
  EngineResult setMute({required bool muted, int channel = 0}) {
    var result = EngineResult.ok;
    for (var lane = 0; lane < laneCount(channel); lane++) {
      final r = setLaneMute(muted: muted, channel: channel, lane: lane);
      if (r != EngineResult.ok) result = r;
    }
    return result;
  }

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
    final result = _applyLaneEffects(channel, lane);
    // A restored chain whose plugin id wasn't in the (cold-start-empty) scan
    // cache lands here as unavailable — kick the one-shot recovery scan.
    _recoverUnavailablePlugins();
    return result;
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

  /// Relinks lane [lane]'s chain entry [index] to plugin [ref] (umbrella
  /// D-MISS), keeping the captured [PluginEffect.state] + paramValues and
  /// clearing the unavailable flag, then reloads it. Use to resolve a
  /// placeholder (uninstalled/moved) or accept a version change. Returns
  /// [EngineResult.invalid] when the entry is not a plugin.
  EngineResult relinkLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required PluginRef ref,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    _laneEffects[(channel, lane)] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(ref: ref, unavailable: false);
    _reproject();
    if (!_intendRunning) return EngineResult.ok;
    // Re-applying reloads the new plugin and restores the preserved state blob.
    return _applyLaneEffects(channel, lane);
  }

  /// Relinks monitor [input]'s chain entry [index] to plugin [ref] (D-MISS),
  /// keeping its state + tweaks. Returns [EngineResult.invalid] when the entry
  /// is not a plugin.
  EngineResult relinkMonitorPlugin({
    required int input,
    required int index,
    required PluginRef ref,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    _monitorEffects[input] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(ref: ref, unavailable: false);
    if (!_intendRunning) return EngineResult.ok;
    return _applyMonitorEffects(input);
  }

  /// Opens the native editor window for lane [lane]'s plugin chain entry
  /// [index] (umbrella D-WIN). Returns [EngineResult.invalid] when no plugin is
  /// loaded there.
  EngineResult openLanePluginEditor({
    required int channel,
    required int lane,
    required int index,
  }) {
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return EngineResult.invalid;
    return _engine.pluginEditorOpen(handle);
  }

  /// Force-closes lane [lane] chain entry [index]'s editor window, then does a
  /// final read-back of its parameters so the editor's last state lands in the
  /// model (D-SYNC; the plugin is the source of truth on conflict).
  EngineResult closeLanePluginEditor({
    required int channel,
    required int lane,
    required int index,
  }) {
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return EngineResult.invalid;
    final result = _engine.pluginEditorClose(handle);
    refreshLanePluginParams(channel: channel, lane: lane, index: index);
    return result;
  }

  /// Whether lane [lane] chain entry [index]'s plugin editor window is still
  /// open natively — false once the user closes the OS window, so the bloc's
  /// sync poll can self-terminate.
  bool isLanePluginEditorOpen({
    required int channel,
    required int lane,
    required int index,
  }) {
    final handle = _laneSlots[(channel, lane, index)];
    return handle != null && _engine.pluginEditorIsOpen(handle);
  }

  /// Reads the live values of lane [lane] chain entry [index]'s user-visible
  /// plugin params back into the model (D-SYNC inbound mirror). Returns whether
  /// anything changed — the bloc's ≤10 Hz editor poll calls this and re-emits
  /// only on a change. A no-op when the entry is not a loaded plugin.
  bool refreshLanePluginParams({
    required int channel,
    required int lane,
    required int index,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) return false;
    final fx = effects[index];
    if (fx is! PluginEffect) return false;
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return false;
    final updated = _readBackParams(fx, handle);
    if (updated == null) return false;
    _laneEffects[(channel, lane)] = List<TrackEffect>.of(effects)
      ..[index] = updated;
    _reproject();
    return true;
  }

  /// Reads every user-visible param of [fx] from its loaded [handle]; returns a
  /// copy with the changed values, or null if nothing moved. Shared by the lane
  /// and monitor read-back paths.
  ///
  /// The plugin is the source of truth (D-SYNC), so a value the plugin reports
  /// overwrites the model. One known transient: an in-app knob set is RT-queued
  /// and applies on the next process block, so a poll that ticks in that window
  /// reads the pre-change value and briefly snaps the knob back. Editor and
  /// in-app knobs are rarely driven at once, so this is accepted for now.
  PluginEffect? _readBackParams(PluginEffect fx, PluginSlotHandle handle) {
    final values = Map<int, double>.of(fx.paramValues);
    var changed = false;
    for (final p in fx.params) {
      if (!p.isUserVisible) continue;
      final live = _engine.pluginParamGet(handle, p.id);
      if (values[p.id] != live) {
        values[p.id] = live;
        changed = true;
      }
    }
    return changed ? fx.copyWith(paramValues: values) : null;
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
      // The plugin failed to load on the running engine — flag the D-MISS
      // placeholder, preserving ref + state for relink (never a silent `none`).
      // A failed load whose id IS in the scan catalog means the plugin is
      // installed but rejected (instrument / multi-bus — D-BUS), as opposed to
      // simply missing; the card shows the right message. On a cold start the
      // catalog is still empty, so this reads as a plain unavailable — which
      // [_recoverUnavailablePlugins] catches, flips to "loading…", and rebinds
      // once its scan lands (F5); clearing `loading` here keeps that transition
      // one-way per apply.
      final installed = _descriptorFor(fx.ref.id) != null;
      return fx.copyWith(
        params: const [],
        unavailable: true,
        unsupported: installed,
        loading: false,
      );
    }
    // Restore the captured opaque state first (D-P1 frozen instance) — a
    // corrupt blob is ignored, never fatal (D-MISS) — then replay the user's
    // param tweaks on top.
    if (fx.state.isNotEmpty) {
      try {
        _engine.pluginStateSet(handle, base64Decode(fx.state));
      } on FormatException {
        // Corrupt blob: leave the plugin at its default state.
      }
    }
    final infos = _enrichParamLabels(
      handle,
      _engine.pluginParamInfos(handle).map(pluginParamInfoFromEngine).toList(),
    );
    for (final entry in fx.paramValues.entries) {
      _engine.pluginParamSet(handle, entry.key, entry.value);
    }
    final descriptor = _descriptorFor(fx.ref.id);
    // The installed version differs from what the take saved (same id, new
    // version) — the plugin still loaded, but note the drift (D-MISS). Drift is
    // only detectable once the catalog has the descriptor, so a false flag here
    // means "no drift OR not yet scanned", never a hard "versions match".
    final versionDrift =
        descriptor != null &&
        fx.ref.version != 0 &&
        descriptor.version != 0 &&
        descriptor.version != fx.ref.version;
    return fx.copyWith(
      params: infos,
      name: descriptor?.name ?? fx.name,
      unavailable: false,
      unsupported: false,
      versionChanged: versionDrift,
      loading: false,
    );
  }

  /// The scanned descriptor for plugin [id], or null when the catalog hasn't
  /// seen it (not yet scanned, or uninstalled).
  PluginDescriptor? _descriptorFor(String id) {
    for (final d in pluginCatalog.descriptors) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// A discrete param with more steps than this stays a knob rather than
  /// becoming a dropdown — enumerating every step of, say, a 128-value param
  /// would be a wall of menu items, not a usable control.
  static const int _maxEnumSteps = 24;

  /// Enriches each small discrete param in [infos] with its per-step display
  /// labels (so the UI can render a switch / dropdown), by asking the plugin to
  /// format every step value. A param whose steps don't all resolve to text is
  /// left bare (it falls back to a knob). Continuous params are untouched.
  List<PluginParamInfo> _enrichParamLabels(
    PluginSlotHandle handle,
    List<PluginParamInfo> infos,
  ) => [
    for (final p in infos)
      if (p.stepCount >= 1 && p.stepCount <= _maxEnumSteps)
        _withStepLabels(handle, p)
      else
        p,
  ];

  PluginParamInfo _withStepLabels(PluginSlotHandle handle, PluginParamInfo p) {
    final labels = <String>[];
    for (var k = 0; k <= p.stepCount; k++) {
      final value = p.min + (p.max - p.min) * k / p.stepCount;
      final text = _engine.pluginParamValueText(handle, p.id, value);
      if (text == null || text.isEmpty) return p; // incomplete -> keep the knob
      labels.add(text);
    }
    return p.withValueTexts(labels);
  }

  /// The plugin's own display string for lane [lane] chain entry [index]'s
  /// parameter [paramId] at the plain [value] (e.g. `-6.0 dB`), or null when no
  /// plugin is loaded there or it offers no text. Drives live knob readouts.
  String? lanePluginParamText({
    required int channel,
    required int lane,
    required int index,
    required int paramId,
    required double value,
  }) {
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return null;
    return _engine.pluginParamValueText(handle, paramId, value);
  }

  /// Like [lanePluginParamText] for monitor [input]'s chain entry [index].
  String? monitorPluginParamText({
    required int input,
    required int index,
    required int paramId,
    required double value,
  }) {
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return null;
    return _engine.pluginParamValueText(handle, paramId, value);
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
    final result = _applyMonitorEffects(input);
    // Same cold-start recovery as setLaneEffects: a restored monitor chain
    // whose plugin wasn't yet scanned lands unavailable — rescan and rebind.
    _recoverUnavailablePlugins();
    return result;
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

  /// Opens the native editor window for monitor [input]'s plugin chain entry
  /// [index] (D-WIN). Returns [EngineResult.invalid] when no plugin is loaded.
  EngineResult openMonitorPluginEditor({
    required int input,
    required int index,
  }) {
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return EngineResult.invalid;
    return _engine.pluginEditorOpen(handle);
  }

  /// Force-closes monitor [input] chain entry [index]'s editor, then reads back
  /// its params so the editor's final state lands in the model (D-SYNC).
  EngineResult closeMonitorPluginEditor({
    required int input,
    required int index,
  }) {
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return EngineResult.invalid;
    final result = _engine.pluginEditorClose(handle);
    refreshMonitorPluginParams(input: input, index: index);
    return result;
  }

  /// Whether monitor [input] chain entry [index]'s plugin editor window is
  /// still open natively (false once the user closes the OS window).
  bool isMonitorPluginEditorOpen({required int input, required int index}) {
    final handle = _monitorSlots[(input, index)];
    return handle != null && _engine.pluginEditorIsOpen(handle);
  }

  /// Reads monitor [input] chain entry [index]'s live plugin param values back
  /// into the model (D-SYNC). Returns whether anything changed. Monitor chains
  /// are not projected, so no `_reproject()` — the MonitorCubit re-reads
  /// [monitorEffects] to emit.
  bool refreshMonitorPluginParams({required int input, required int index}) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) return false;
    final fx = effects[index];
    if (fx is! PluginEffect) return false;
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return false;
    final updated = _readBackParams(fx, handle);
    if (updated == null) return false;
    _monitorEffects[input] = List<TrackEffect>.of(effects)..[index] = updated;
    return true;
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
