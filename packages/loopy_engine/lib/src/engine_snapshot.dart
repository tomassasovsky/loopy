import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:meta/meta.dart';

/// Phase of the loopback round-trip latency harness.
///
/// Mirrors the native `le_latency_state` enum.
enum LatencyState {
  /// No measurement has been requested.
  idle,

  /// An impulse has been emitted and the engine is waiting for it to return.
  measuring,

  /// A measurement completed; [EngineSnapshot.measuredLatencyMs] is valid.
  done,

  /// No loopback signal was detected within the measurement window.
  timeout;

  /// Maps a native `le_latency_state` integer to a [LatencyState].
  static LatencyState fromCode(int code) => switch (code) {
    0 => LatencyState.idle,
    1 => LatencyState.measuring,
    2 => LatencyState.done,
    3 => LatencyState.timeout,
    _ => LatencyState.idle,
  };
}

/// The per-track looper state machine.
///
/// Mirrors the native `le_track_state` enum.
enum TrackState {
  /// No audio captured yet.
  empty,

  /// Capturing the first pass (or overwriting one loop on a new track).
  recording,

  /// Summing input into the existing loop.
  overdubbing,

  /// Looping playback.
  playing,

  /// Playback halted; the loop buffer is retained.
  stopped;

  /// Maps a native `le_track_state` integer to a [TrackState].
  static TrackState fromCode(int code) => switch (code) {
    0 => TrackState.empty,
    1 => TrackState.recording,
    2 => TrackState.overdubbing,
    3 => TrackState.playing,
    4 => TrackState.stopped,
    _ => TrackState.empty,
  };
}

/// An immutable per-track projection of the native `le_track_snapshot`.
@immutable
class TrackSnapshot {
  /// Creates a [TrackSnapshot].
  const TrackSnapshot({
    required this.state,
    required this.volume,
    required this.muted,
    required this.lengthFrames,
    required this.undoDepth,
    required this.rms,
    required this.peak,
    this.redoDepth = 0,
  });

  /// An empty track.
  const TrackSnapshot.empty()
    : state = TrackState.empty,
      volume = 1,
      muted = false,
      lengthFrames = 0,
      undoDepth = 0,
      redoDepth = 0,
      rms = 0,
      peak = 0;

  /// Projects a native `le_track_snapshot` into a [TrackSnapshot].
  factory TrackSnapshot.fromNative(le_track_snapshot native) => TrackSnapshot(
    state: TrackState.fromCode(native.state),
    volume: native.volume,
    muted: native.muted != 0,
    lengthFrames: native.length_frames,
    undoDepth: native.undo_depth,
    redoDepth: native.redo_depth,
    rms: native.rms,
    peak: native.peak,
  );

  /// State-machine phase.
  final TrackState state;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the track is muted.
  final bool muted;

  /// Captured length in frames (equals master once finalized).
  final int lengthFrames;

  /// Available undo steps (overdub layers).
  final int undoDepth;

  /// Available redo steps.
  final int redoDepth;

  /// RMS level for the most recent block, in `0..1`.
  final double rms;

  /// Peak level for the most recent block, in `0..1`.
  final double peak;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackSnapshot &&
          runtimeType == other.runtimeType &&
          state == other.state &&
          volume == other.volume &&
          muted == other.muted &&
          lengthFrames == other.lengthFrames &&
          undoDepth == other.undoDepth &&
          redoDepth == other.redoDepth &&
          rms == other.rms &&
          peak == other.peak;

  @override
  int get hashCode => Object.hash(
    state,
    volume,
    muted,
    lengthFrames,
    undoDepth,
    redoDepth,
    rms,
    peak,
  );
}

/// An immutable, lock-free snapshot of the native audio engine's state.
///
/// Published by the engine's audio thread and read by Dart on a render-rate
/// timer. The pure-Dart projection of the native `le_snapshot` struct.
@immutable
class EngineSnapshot {
  /// Creates an [EngineSnapshot] with explicit values.
  const EngineSnapshot({
    required this.isRunning,
    required this.sampleRate,
    required this.bufferFrames,
    required this.channels,
    required this.framesProcessed,
    required this.xrunCount,
    required this.inputRms,
    required this.inputPeak,
    required this.outputRms,
    required this.latencyState,
    required this.measuredLatencyMs,
    this.masterLengthFrames = 0,
    this.masterPositionFrames = 0,
    this.tempoBpm = 120,
    this.metronomeOn = false,
    this.countInEnabled = false,
    this.countingIn = false,
    this.currentBeat = 0,
    this.recordOffsetFrames = 0,
    this.tracks = const [],
  });

  /// The snapshot of an engine that has never started.
  const EngineSnapshot.initial()
    : isRunning = false,
      sampleRate = 0,
      bufferFrames = 0,
      channels = 0,
      framesProcessed = 0,
      xrunCount = 0,
      inputRms = 0,
      inputPeak = 0,
      outputRms = 0,
      latencyState = LatencyState.idle,
      measuredLatencyMs = -1,
      masterLengthFrames = 0,
      masterPositionFrames = 0,
      tempoBpm = 120,
      metronomeOn = false,
      countInEnabled = false,
      countingIn = false,
      currentBeat = 0,
      recordOffsetFrames = 0,
      tracks = const [];

  /// Projects a native `le_snapshot` struct (scalars) plus the already-read
  /// [tracks] into an [EngineSnapshot].
  ///
  /// Tracks are read separately (via `le_engine_get_track`) because this ffi
  /// version cannot index a native struct array.
  factory EngineSnapshot.fromNative(
    le_snapshot native,
    List<TrackSnapshot> tracks,
  ) => EngineSnapshot(
    isRunning: native.running != 0,
    sampleRate: native.sample_rate,
    bufferFrames: native.buffer_frames,
    channels: native.channels,
    framesProcessed: native.frames_processed,
    xrunCount: native.xrun_count,
    inputRms: native.input_rms,
    inputPeak: native.input_peak,
    outputRms: native.output_rms,
    latencyState: LatencyState.fromCode(native.latency_state),
    measuredLatencyMs: native.measured_latency_ms,
    masterLengthFrames: native.master_length_frames,
    masterPositionFrames: native.master_position_frames,
    tempoBpm: native.tempo_bpm,
    metronomeOn: native.metronome_on != 0,
    countInEnabled: native.count_in_enabled != 0,
    countingIn: native.counting_in != 0,
    currentBeat: native.current_beat,
    recordOffsetFrames: native.record_offset_frames,
    tracks: tracks,
  );

  /// Whether the audio device is open and the callback is running.
  final bool isRunning;

  /// Negotiated device sample rate in Hz.
  final int sampleRate;

  /// Negotiated device period (buffer) size in frames.
  final int bufferFrames;

  /// Number of channels in the duplex stream.
  final int channels;

  /// Total frames processed by the audio callback since the device started.
  final int framesProcessed;

  /// Device xruns since the device started (reserved; currently `0`).
  final int xrunCount;

  /// Input RMS level for the most recent block, in `0..1`.
  final double inputRms;

  /// Input peak level for the most recent block, in `0..1`.
  final double inputPeak;

  /// Output RMS level for the most recent block, in `0..1`.
  final double outputRms;

  /// Phase of the latency harness.
  final LatencyState latencyState;

  /// Measured round-trip latency in milliseconds, valid only when
  /// [latencyState] is [LatencyState.done]; otherwise `-1` or stale.
  final double measuredLatencyMs;

  /// Master loop length in frames; `0` until the first recording is finalized.
  final int masterLengthFrames;

  /// Current master loop playhead in frames.
  final int masterPositionFrames;

  /// Current tempo in beats per minute.
  final double tempoBpm;

  /// Whether the metronome click is enabled.
  final bool metronomeOn;

  /// Whether a count-in precedes the first recording.
  final bool countInEnabled;

  /// Whether a count-in is currently in progress.
  final bool countingIn;

  /// The current beat within the bar (`0..3`).
  final int currentBeat;

  /// Record-offset latency compensation in frames (auto-set by a measurement).
  final int recordOffsetFrames;

  /// Per-track snapshots (length == active track count).
  final List<TrackSnapshot> tracks;

  /// The number of tracks.
  int get trackCount => tracks.length;

  TrackSnapshot get _track0 =>
      tracks.isNotEmpty ? tracks.first : const TrackSnapshot.empty();

  /// Track 0 state (back-compat single-track accessor).
  TrackState get trackState => _track0.state;

  /// Track 0 volume (back-compat single-track accessor).
  double get trackVolume => _track0.volume;

  /// Track 0 mute (back-compat single-track accessor).
  bool get trackMuted => _track0.muted;

  /// Track 0 length (back-compat single-track accessor).
  int get trackLengthFrames => _track0.lengthFrames;

  /// Track 0 undo depth (back-compat single-track accessor).
  int get trackUndoDepth => _track0.undoDepth;

  /// Track 0 RMS (back-compat single-track accessor).
  double get trackRms => _track0.rms;

  /// Track 0 peak (back-compat single-track accessor).
  double get trackPeak => _track0.peak;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineSnapshot &&
          runtimeType == other.runtimeType &&
          isRunning == other.isRunning &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          channels == other.channels &&
          framesProcessed == other.framesProcessed &&
          xrunCount == other.xrunCount &&
          inputRms == other.inputRms &&
          inputPeak == other.inputPeak &&
          outputRms == other.outputRms &&
          latencyState == other.latencyState &&
          measuredLatencyMs == other.measuredLatencyMs &&
          masterLengthFrames == other.masterLengthFrames &&
          masterPositionFrames == other.masterPositionFrames &&
          tempoBpm == other.tempoBpm &&
          metronomeOn == other.metronomeOn &&
          countInEnabled == other.countInEnabled &&
          countingIn == other.countingIn &&
          currentBeat == other.currentBeat &&
          recordOffsetFrames == other.recordOffsetFrames &&
          _listEquals(tracks, other.tracks);

  @override
  int get hashCode => Object.hashAll([
    isRunning,
    sampleRate,
    bufferFrames,
    channels,
    framesProcessed,
    xrunCount,
    inputRms,
    inputPeak,
    outputRms,
    latencyState,
    measuredLatencyMs,
    masterLengthFrames,
    masterPositionFrames,
    tempoBpm,
    metronomeOn,
    countInEnabled,
    countingIn,
    currentBeat,
    recordOffsetFrames,
    ...tracks,
  ]);

  @override
  String toString() =>
      'EngineSnapshot(running: $isRunning, '
      'sampleRate: $sampleRate, tracks: $trackCount, '
      'master: $masterPositionFrames/$masterLengthFrames, '
      'latency: ${latencyState.name}/$measuredLatencyMs ms)';
}

bool _listEquals(List<TrackSnapshot> a, List<TrackSnapshot> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
