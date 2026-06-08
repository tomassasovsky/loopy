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

  /// Distinct stream of looper states.
  Stream<LooperState> get looperState => _controller.stream;

  /// The current state, read synchronously from the engine.
  LooperState get state => _project(_engine.snapshot());

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
    track: Track(
      state: s.trackState,
      volume: s.trackVolume,
      muted: s.trackMuted,
      lengthFrames: s.trackLengthFrames,
      playheadFrames: s.masterPositionFrames,
      rms: s.trackRms,
      peak: s.trackPeak,
      undoDepth: s.trackUndoDepth,
    ),
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
  EngineResult startEngine(EngineConfig config) => _engine.start(config);

  /// Closes the audio device.
  EngineResult stopEngine() => _engine.stop();

  /// Detects a cable-free loopback capture path for auto-measuring latency.
  LoopbackInfo detectLoopback() => _engine.detectLoopback();

  /// Triggers a loopback round-trip latency measurement.
  EngineResult measureLatency() => _engine.measureLatency();

  /// Advances the track: record / finalize loop / toggle overdub.
  EngineResult record() => _engine.record();

  /// Halts track playback (retaining the buffer).
  EngineResult stopTrack() => _engine.stopTrack();

  /// Resumes playback of a stopped track.
  EngineResult play() => _engine.play();

  /// Erases the track and resets the master loop.
  EngineResult clear() => _engine.clear();

  /// Removes the last overdub layer.
  EngineResult undo() => _engine.undo();

  /// Sets track playback gain (`0..1`).
  EngineResult setVolume(double volume) => _engine.setTrackVolume(volume);

  /// Mutes or unmutes the track.
  EngineResult setMute({required bool muted}) =>
      _engine.setTrackMute(muted: muted);

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
