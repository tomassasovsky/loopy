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
  }) : _engine = engine,
       _ticker = ticker,
       _pollInterval = pollInterval {
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
  final Duration _pollInterval;
  late final StreamController<LooperState> _controller;
  StreamSubscription<void>? _tickerSub;
  Timer? _pollTimer;
  LooperState? _last;
  EngineConfig? _lastEngineConfig;

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
      recordOffsetFrames: s.recordOffsetFrames,
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
  EngineResult setInputMask({required int channel, required int mask}) =>
      _engine.setInputMask(channel: channel, mask: mask);

  /// Routes track [channel]'s playback to the output channels set in [mask].
  EngineResult setOutputMask({required int channel, required int mask}) =>
      _engine.setOutputMask(channel: channel, mask: mask);

  /// Reads the loop waveform (peaks indexed by loop position, `0..1`) of the
  /// mixed output for the visualizer.
  Float32List readWaveform() => _engine.readVisual();

  /// Reads track [channel]'s loop waveform for a per-track thumbnail.
  Float32List readTrackWaveform(int channel) =>
      _engine.readTrackVisual(channel);

  /// Sets the record-offset latency compensation in frames.
  EngineResult setRecordOffset(int frames) => _engine.setRecordOffset(frames);

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
