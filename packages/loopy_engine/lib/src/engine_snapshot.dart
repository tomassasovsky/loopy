import 'package:loopy_engine/src/engine_config.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:meta/meta.dart';

/// The maximum number of lanes a single track can hold, mirroring the native
/// `LE_MAX_LANES`. Referenced (not re-typed) so it can never drift from the C.
const int kMaxLanes = LE_MAX_LANES;

/// The maximum number of monitorable hardware inputs, mirroring the native
/// `LE_MAX_INPUTS`. Referenced (not re-typed) so it can never drift from the C.
const int kMaxInputs = LE_MAX_INPUTS;

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

/// An immutable per-lane projection of the native `le_lane_snapshot`.
///
/// A lane is a track's fundamental recordable unit: it records one hardware
/// input ([inputChannel], `-1` = none) into its own clean mono buffer and plays
/// that buffer — through its own effect chain — to the outputs in [outputMask].
@immutable
class LaneSnapshot {
  /// Creates a [LaneSnapshot].
  const LaneSnapshot({
    required this.inputChannel,
    required this.outputMask,
    required this.volume,
    required this.muted,
    required this.lengthFrames,
    required this.rms,
    required this.peak,
  });

  /// An empty lane recording no input.
  const LaneSnapshot.empty()
    : inputChannel = -1,
      outputMask = 0x3,
      volume = 1,
      muted = false,
      lengthFrames = 0,
      rms = 0,
      peak = 0;

  /// Projects a native `le_lane_snapshot` into a [LaneSnapshot].
  factory LaneSnapshot.fromNative(le_lane_snapshot native) => LaneSnapshot(
    inputChannel: native.input_channel,
    outputMask: native.output_mask,
    volume: native.volume,
    muted: native.muted != 0,
    lengthFrames: native.length_frames,
    rms: native.rms,
    peak: native.peak,
  );

  /// Hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  /// Bitmask of hardware output channels this lane plays to (bit c => out c).
  final int outputMask;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// Captured length of this lane's buffer in frames.
  final int lengthFrames;

  /// RMS level for the most recent block, in `0..1`.
  final double rms;

  /// Peak level for the most recent block, in `0..1`.
  final double peak;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LaneSnapshot &&
          runtimeType == other.runtimeType &&
          inputChannel == other.inputChannel &&
          outputMask == other.outputMask &&
          volume == other.volume &&
          muted == other.muted &&
          lengthFrames == other.lengthFrames &&
          rms == other.rms &&
          peak == other.peak;

  @override
  int get hashCode => Object.hash(
    inputChannel,
    outputMask,
    volume,
    muted,
    lengthFrames,
    rms,
    peak,
  );
}

/// An immutable per-track projection of the native `le_track_snapshot`.
///
/// A track is a multi-lane container: it owns the transport (state, multiple,
/// undo/redo depth) and its [lanes]. The scalar [volume]/[muted]/[lengthFrames]/
/// [rms]/[peak]/[inputMask]/[outputMask] fields mirror lane 0 for back-compat
/// single-lane accessors; per-lane state lives in [lanes].
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
    this.multiple = 1,
    this.inputMask = 0x1,
    this.outputMask = 0x3,
    this.layerInFlight = false,
    this.pending = false,
    this.lanes = const <LaneSnapshot>[],
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
      peak = 0,
      multiple = 1,
      inputMask = 0x1,
      outputMask = 0x3,
      layerInFlight = false,
      pending = false,
      lanes = const <LaneSnapshot>[];

  /// Projects a native `le_track_snapshot` into a [TrackSnapshot].
  ///
  /// [lanes] are read separately (via `le_engine_get_lane`, one per active
  /// lane) because this ffi version cannot index a native struct array; their
  /// length is `native.lane_count`.
  factory TrackSnapshot.fromNative(
    le_track_snapshot native, [
    List<LaneSnapshot> lanes = const [],
  ]) => TrackSnapshot(
    state: TrackState.fromCode(native.state),
    volume: native.volume,
    muted: native.muted != 0,
    lengthFrames: native.length_frames,
    undoDepth: native.undo_depth,
    redoDepth: native.redo_depth,
    rms: native.rms,
    peak: native.peak,
    multiple: native.multiple,
    inputMask: native.input_mask,
    outputMask: native.output_mask,
    layerInFlight: native.layer_in_flight != 0,
    pending: native.pending != 0,
    lanes: lanes,
  );

  /// State-machine phase.
  final TrackState state;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the track is muted.
  final bool muted;

  /// Captured length in frames (equals `multiple` × the master length).
  final int lengthFrames;

  /// Track length in whole base loops (`>= 1`); `> 1` for a loop multiple.
  final int multiple;

  /// Available undo steps (overdub layers).
  final int undoDepth;

  /// Available redo steps.
  final int redoDepth;

  /// Whether an overdub undo layer is still being captured or drained (the
  /// punch-tail window). Session capture waits this out before exporting.
  final bool layerInFlight;

  /// Whether a quantized/signal-triggered record arm is waiting to fire.
  final bool pending;

  /// RMS level for the most recent block, in `0..1`.
  final double rms;

  /// Peak level for the most recent block, in `0..1`.
  final double peak;

  /// Lane 0's recorded input as a bitmask (`1 << inputChannel`, or `0` when
  /// lane 0 records no input). Mirrors lane 0; per-lane inputs are in [lanes].
  final int inputMask;

  /// Bitmask of hardware output channels this track plays to (bit c => out c).
  /// Mirrors lane 0.
  final int outputMask;

  /// Per-lane snapshots, in lane order.
  ///
  /// Populated by the native engine's `snapshot()` with one entry per active
  /// lane (read via `le_engine_get_lane`); empty in synthetic snapshots such as
  /// [TrackSnapshot.empty].
  final List<LaneSnapshot> lanes;

  /// The number of active lanes (equals [lanes] length).
  int get laneCount => lanes.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackSnapshot &&
          runtimeType == other.runtimeType &&
          state == other.state &&
          volume == other.volume &&
          muted == other.muted &&
          lengthFrames == other.lengthFrames &&
          multiple == other.multiple &&
          undoDepth == other.undoDepth &&
          redoDepth == other.redoDepth &&
          rms == other.rms &&
          peak == other.peak &&
          inputMask == other.inputMask &&
          outputMask == other.outputMask &&
          layerInFlight == other.layerInFlight &&
          pending == other.pending &&
          _listEquals(lanes, other.lanes);

  @override
  int get hashCode => Object.hash(
    state,
    volume,
    muted,
    lengthFrames,
    multiple,
    undoDepth,
    redoDepth,
    rms,
    peak,
    inputMask,
    outputMask,
    layerInFlight,
    pending,
    Object.hashAll(lanes),
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
    required this.framesProcessed,
    required this.xrunCount,
    required this.inputRms,
    required this.inputPeak,
    required this.outputRms,
    required this.latencyState,
    required this.measuredLatencyMs,
    this.devicePresent = false,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.excludedInputMask = 0,
    this.masterLengthFrames = 0,
    this.masterPositionFrames = 0,
    this.recordOffsetFrames = 0,
    this.fxAddedLatencyFrames = 0,
    this.masterGain = 1,
    this.activeBackend = AudioBackend.miniaudio,
    this.outputEnabledMask = 0xFFFFFFFF,
    this.isPerfArmed = false,
    this.perfFrames = 0,
    this.perfOverruns = 0,
    this.tracks = const [],
  });

  /// The snapshot of an engine that has never started.
  const EngineSnapshot.initial()
    : isRunning = false,
      devicePresent = false,
      sampleRate = 0,
      bufferFrames = 0,
      inputChannels = 0,
      outputChannels = 0,
      excludedInputMask = 0,
      framesProcessed = 0,
      xrunCount = 0,
      inputRms = 0,
      inputPeak = 0,
      outputRms = 0,
      latencyState = LatencyState.idle,
      measuredLatencyMs = -1,
      masterLengthFrames = 0,
      masterPositionFrames = 0,
      recordOffsetFrames = 0,
      fxAddedLatencyFrames = 0,
      masterGain = 1,
      activeBackend = AudioBackend.miniaudio,
      outputEnabledMask = 0xFFFFFFFF,
      isPerfArmed = false,
      perfFrames = 0,
      perfOverruns = 0,
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
    devicePresent: native.device_present != 0,
    sampleRate: native.sample_rate,
    bufferFrames: native.buffer_frames,
    inputChannels: native.input_channels,
    outputChannels: native.output_channels,
    excludedInputMask: native.excluded_input_mask,
    framesProcessed: native.frames_processed,
    xrunCount: native.xrun_count,
    inputRms: native.input_rms,
    inputPeak: native.input_peak,
    outputRms: native.output_rms,
    latencyState: LatencyState.fromCode(native.latency_state),
    measuredLatencyMs: native.measured_latency_ms,
    masterLengthFrames: native.master_length_frames,
    masterPositionFrames: native.master_position_frames,
    recordOffsetFrames: native.record_offset_frames,
    fxAddedLatencyFrames: native.fx_added_latency_frames,
    masterGain: native.master_gain,
    activeBackend: AudioBackend.fromNative(native.active_backend),
    outputEnabledMask: native.output_enabled_mask,
    isPerfArmed: native.perf_armed != 0,
    perfFrames: native.perf_frames,
    perfOverruns: native.perf_overruns,
    tracks: tracks,
  );

  /// Whether the audio device is open and the callback is running.
  final bool isRunning;

  /// Whether the pinned (or default) device is currently present.
  ///
  /// Distinct from [isRunning]: a device can be lost (e.g. unplugged) while the
  /// engine object still reports running until it is restarted. Flips to
  /// `false` on a device-lost / rerouted / interrupted notification.
  final bool devicePresent;

  /// Negotiated device sample rate in Hz.
  final int sampleRate;

  /// Negotiated device period (buffer) size in frames.
  final int bufferFrames;

  /// Negotiated hardware capture channel count.
  final int inputChannels;

  /// Negotiated hardware playback channel count.
  final int outputChannels;

  /// Bitmask of input channels excluded as loopback (never recorded, monitored,
  /// or routable). `0` when nothing is excluded (always so off macOS).
  final int excludedInputMask;

  /// Total frames processed by the audio callback since the device started.
  final int framesProcessed;

  /// Device dropouts (xruns) since the device started, as reported by the
  /// backend. The Windows ASIO backend tallies the driver's overload
  /// notifications; the miniaudio backends (macOS / Linux) expose no portable
  /// xrun signal, so this stays `0` there. Monotonic; resets on each start.
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

  /// Record-offset latency compensation in frames (auto-set by a measurement).
  final int recordOffsetFrames;

  /// Added latency (frames) of the highest-latency effect engaged in any
  /// audible or monitored lane chain — the maximum across active effects. Today
  /// only the formant-preserving octaver contributes (~21 ms); `0` when no
  /// octaver is engaged. Purely informational (see [fxAddedLatencyMs]); never
  /// feeds [recordOffsetFrames] or any compensation.
  final int fxAddedLatencyFrames;

  /// [fxAddedLatencyFrames] expressed in milliseconds at the current
  /// [sampleRate]; `0` when no effect adds latency or the rate is unknown.
  double get fxAddedLatencyMs =>
      sampleRate > 0 ? fxAddedLatencyFrames * 1000 / sampleRate : 0;

  /// Global master output gain in `0..1`, applied post-mix to the final output.
  /// Unity (`1.0`) by default and after every fresh start.
  final double masterGain;

  /// The device backend actually running (negotiated). Always
  /// [AudioBackend.miniaudio] today; in Part 2 a requested-ASIO open that fell
  /// back reports [AudioBackend.miniaudio] here.
  final AudioBackend activeBackend;

  /// Structural output gate: bit c set => hardware output c is enabled (a
  /// routing target). A cleared bit removes it from the mix while its stored
  /// route masks are preserved (re-enabling restores them). All outputs are
  /// enabled by default; only bits in `[0, outputChannels)` are meaningful.
  /// (The domain-level `LooperState.isOutputEnabled` interprets this bit.)
  final int outputEnabledMask;

  /// Whether performance-recording capture is armed (`AudioEngine.perfArm` /
  /// `AudioEngine.perfDisarm`) — the RT taps are actively copying the master
  /// output (and each captured monitor input) into the capture rings.
  final bool isPerfArmed;

  /// Frames processed since the most recent `AudioEngine.perfArm`, regardless
  /// of any capture ring dropping frames. `0` when never armed.
  final int perfFrames;

  /// Capture frames dropped (a full ring) since the most recent
  /// `AudioEngine.perfArm`. `0` when never armed or nothing has overflowed.
  final int perfOverruns;

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
          devicePresent == other.devicePresent &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          inputChannels == other.inputChannels &&
          outputChannels == other.outputChannels &&
          excludedInputMask == other.excludedInputMask &&
          framesProcessed == other.framesProcessed &&
          xrunCount == other.xrunCount &&
          inputRms == other.inputRms &&
          inputPeak == other.inputPeak &&
          outputRms == other.outputRms &&
          latencyState == other.latencyState &&
          measuredLatencyMs == other.measuredLatencyMs &&
          masterLengthFrames == other.masterLengthFrames &&
          masterPositionFrames == other.masterPositionFrames &&
          recordOffsetFrames == other.recordOffsetFrames &&
          fxAddedLatencyFrames == other.fxAddedLatencyFrames &&
          masterGain == other.masterGain &&
          activeBackend == other.activeBackend &&
          outputEnabledMask == other.outputEnabledMask &&
          isPerfArmed == other.isPerfArmed &&
          perfFrames == other.perfFrames &&
          perfOverruns == other.perfOverruns &&
          _listEquals(tracks, other.tracks);

  @override
  int get hashCode => Object.hashAll([
    isRunning,
    devicePresent,
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    excludedInputMask,
    framesProcessed,
    xrunCount,
    inputRms,
    inputPeak,
    outputRms,
    latencyState,
    measuredLatencyMs,
    masterLengthFrames,
    masterPositionFrames,
    recordOffsetFrames,
    fxAddedLatencyFrames,
    masterGain,
    activeBackend,
    outputEnabledMask,
    isPerfArmed,
    perfFrames,
    perfOverruns,
    ...tracks,
  ]);

  @override
  String toString() =>
      'EngineSnapshot(running: $isRunning, '
      'devicePresent: $devicePresent, '
      'sampleRate: $sampleRate, tracks: $trackCount, '
      'backend: ${activeBackend.name}, '
      'master: $masterPositionFrames/$masterLengthFrames, '
      'latency: ${latencyState.name}/$measuredLatencyMs ms)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
