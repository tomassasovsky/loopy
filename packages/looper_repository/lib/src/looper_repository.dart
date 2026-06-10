import 'dart:async';
import 'dart:typed_data';

import 'package:looper_repository/src/models/engine_status.dart';
import 'package:looper_repository/src/models/looper_state.dart';
import 'package:looper_repository/src/models/track.dart';
import 'package:looper_repository/src/models/transport_state.dart';
import 'package:loopy_engine/loopy_engine.dart';

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

  /// Creates a repository driving the real native miniaudio engine, so the app
  /// composes the looper without importing the data layer (`loopy_engine`)
  /// directly.
  factory LooperRepository.withNativeEngine() =>
      LooperRepository(engine: NativeAudioEngine());

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

  /// Monitor routing, re-applied on every successful (re)start. The custom
  /// masks default to input 0 -> outputs 0 + 1 (the engine default); when
  /// [_monitorFollowChannel] is non-null the monitor mirrors that track.
  int _monitorInputMask = 0x1;
  int _monitorOutputMask = 0x3;
  int? _monitorFollowChannel;

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
    final devices = _engine.enumerateDevices();
    if (!_pinnedDevicesPresent(config, devices)) {
      return; // still absent — keep waiting
    }
    final signature = devices
        .map((d) => '${d.isInput ? 'i' : 'o'}:${d.id}')
        .join('|');
    if (signature == _lastAttemptSignature) return; // already tried this set
    _lastAttemptSignature = signature;
    _engine.stop();
    if (_engine.start(config).isOk) _stopReconnectPolling();
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
        ),
    ],
    status: EngineStatus(
      deviceName: _engine.deviceName,
      sampleRate: s.sampleRate,
      bufferFrames: s.bufferFrames,
      inputChannels: s.inputChannels,
      outputChannels: s.outputChannels,
      latencyState: s.latencyState,
      measuredLatencyMs: s.measuredLatencyMs,
      xrunCount: s.xrunCount,
      isConnected: s.isRunning,
      devicePresent: s.devicePresent,
      excludedInputMask: s.excludedInputMask,
      recordOffsetFrames: s.recordOffsetFrames,
    ),
  );

  /// Enumerates the host's audio devices (playback + capture) for the picker.
  List<AudioDevice> devices() => _engine.enumerateDevices();

  /// Opens the audio device and starts processing.
  EngineResult startEngine(EngineConfig config) {
    final result = _engine.start(config);
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
      _applyMonitor();
    }
    return result;
  }

  /// Closes the audio device. A deliberate stop also cancels any in-flight
  /// reconnect supervision so the engine is not reopened behind the user.
  EngineResult stopEngine() {
    _intendRunning = false;
    _stopReconnectPolling();
    return _engine.stop();
  }

  /// Detects a cable-free loopback capture path for auto-measuring latency.
  LoopbackInfo detectLoopback() => _engine.detectLoopback();

  /// Triggers a loopback round-trip latency measurement.
  EngineResult measureLatency() => _engine.measureLatency();

  /// Advances track [channel]: record / finalize loop / toggle overdub.
  EngineResult record({int channel = 0}) => _engine.record(channel: channel);

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

  /// Sets track [channel]'s playback gain (`0..1`).
  EngineResult setVolume(double volume, {int channel = 0}) =>
      _engine.setTrackVolume(volume, channel: channel);

  /// Mutes or unmutes track [channel].
  EngineResult setMute({required bool muted, int channel = 0}) =>
      _engine.setTrackMute(muted: muted, channel: channel);

  /// Routes track [channel]'s record sources to the input channels in [mask].
  /// When monitoring follows this track, the monitor input mask tracks it.
  EngineResult setInputMask({required int channel, required int mask}) {
    final result = _engine.setInputMask(channel: channel, mask: mask);
    if (_intendRunning && _monitorFollowChannel == channel) {
      _engine.setMonitorInputMask(mask: mask);
    }
    return result;
  }

  /// Routes track [channel]'s playback to the output channels set in [mask].
  /// When monitoring follows this track, the monitor output mask tracks it.
  EngineResult setOutputMask({required int channel, required int mask}) {
    final result = _engine.setOutputMask(channel: channel, mask: mask);
    if (_intendRunning && _monitorFollowChannel == channel) {
      _engine.setMonitorOutputMask(mask: mask);
    }
    return result;
  }

  /// Sets the monitor input mask (custom mode): which input channels are
  /// averaged into the live monitor. Remembered and re-applied on start; takes
  /// effect immediately only while running and not following a track.
  EngineResult setMonitorInputMask(int mask) {
    _monitorInputMask = mask;
    if (_intendRunning && _monitorFollowChannel == null) {
      return _engine.setMonitorInputMask(mask: mask);
    }
    return EngineResult.ok;
  }

  /// Sets the monitor output mask (custom mode): which output channels the
  /// monitor is routed to. Remembered and re-applied on start.
  EngineResult setMonitorOutputMask(int mask) {
    _monitorOutputMask = mask;
    if (_intendRunning && _monitorFollowChannel == null) {
      return _engine.setMonitorOutputMask(mask: mask);
    }
    return EngineResult.ok;
  }

  /// Selects what the monitor routes: a track [channel] to mirror that track's
  /// input/output routing, or `null` for the custom monitor masks. Remembered
  /// and re-applied on start.
  void setMonitorFollowTrack(int? channel) {
    _monitorFollowChannel = channel;
    _applyMonitor();
  }

  /// Pushes the effective monitor masks to the engine: the followed track's
  /// masks, or the custom masks. No-op while not running.
  void _applyMonitor() {
    if (!_intendRunning) return;
    final follow = _monitorFollowChannel;
    if (follow != null) {
      final tracks = _engine.snapshot().tracks;
      if (follow >= 0 && follow < tracks.length) {
        _engine
          ..setMonitorInputMask(mask: tracks[follow].inputMask)
          ..setMonitorOutputMask(mask: tracks[follow].outputMask);
      }
      return;
    }
    _engine
      ..setMonitorInputMask(mask: _monitorInputMask)
      ..setMonitorOutputMask(mask: _monitorOutputMask);
  }

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
