import 'dart:async';

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
  }) : _engine = engine,
       _ticker = ticker ?? Stream<void>.periodic(pollInterval) {
    _controller = StreamController<LooperState>.broadcast(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
  }

  final AudioEngine _engine;
  final Stream<void> _ticker;
  late final StreamController<LooperState> _controller;
  StreamSubscription<void>? _tickerSub;
  LooperState? _last;
  EngineConfig? _lastEngineConfig;

  /// Distinct stream of looper states.
  Stream<LooperState> get looperState => _controller.stream;

  /// The current state, read synchronously from the engine.
  LooperState get state => _project(_engine.snapshot());

  /// The most recent config passed to [startEngine], or `null` before the first
  /// successful start.
  EngineConfig? get lastEngineConfig => _lastEngineConfig;

  /// The engine + miniaudio version string.
  String get engineVersion => _engine.version;

  void _startPolling() {
    _tickerSub = _ticker.listen((_) => _poll());
    _poll();
  }

  void _stopPolling() {
    unawaited(_tickerSub?.cancel());
    _tickerSub = null;
  }

  void _poll() {
    final next = _project(_engine.snapshot());
    if (next == _last) return;
    _last = next;
    _controller.add(next);
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
        ),
    ],
    status: EngineStatus(
      deviceName: _engine.deviceName,
      sampleRate: s.sampleRate,
      bufferFrames: s.bufferFrames,
      channels: s.channels,
      latencyState: s.latencyState,
      measuredLatencyMs: s.measuredLatencyMs,
      xrunCount: s.xrunCount,
      isConnected: s.isRunning,
    ),
  );

  /// Opens the audio device and starts processing.
  EngineResult startEngine(EngineConfig config) {
    final result = _engine.start(config);
    if (result.isOk) _lastEngineConfig = config;
    return result;
  }

  /// Closes the audio device.
  EngineResult stopEngine() => _engine.stop();

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

  /// Removes the last overdub layer on track [channel].
  EngineResult undo({int channel = 0}) => _engine.undo(channel: channel);

  /// Sets track [channel]'s playback gain (`0..1`).
  EngineResult setVolume(double volume, {int channel = 0}) =>
      _engine.setTrackVolume(volume, channel: channel);

  /// Mutes or unmutes track [channel].
  EngineResult setMute({required bool muted, int channel = 0}) =>
      _engine.setTrackMute(muted: muted, channel: channel);

  /// Releases the repository and the underlying engine.
  Future<void> dispose() async {
    await _stopPollingAndClose();
    _engine.dispose();
  }

  Future<void> _stopPollingAndClose() async {
    _stopPolling();
    await _controller.close();
  }
}
