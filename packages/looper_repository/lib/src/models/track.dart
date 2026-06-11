import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/lane.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// A single looper track: a multi-lane container that owns the transport
/// (state, loop multiple, undo/redo depth) and its [lanes].
///
/// The scalar [volume]/[muted]/[inputMask]/[outputMask]/[rms]/[peak] fields
/// mirror lane 0 so existing single-lane callers (the channel strip, the
/// routing graph) keep working; full per-lane state lives in [lanes].
class Track extends Equatable {
  /// Creates a [Track].
  const Track({
    this.channel = 0,
    this.state = TrackState.empty,
    this.volume = 1,
    this.muted = false,
    this.lengthFrames = 0,
    this.playheadFrames = 0,
    this.rms = 0,
    this.peak = 0,
    this.undoDepth = 0,
    this.redoDepth = 0,
    this.multiple = 1,
    this.inputMask = 0x1,
    this.outputMask = 0x3,
    this.lanes = const [],
  });

  /// Track channel index (always 0 in the single-track phase).
  final int channel;

  /// Current state-machine phase.
  final TrackState state;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the track is muted.
  final bool muted;

  /// Captured length in frames (equals the master loop once finalized).
  final int lengthFrames;

  /// Current playhead in frames.
  final int playheadFrames;

  /// RMS level for the most recent block, in `0..1`.
  final double rms;

  /// Peak level for the most recent block, in `0..1`.
  final double peak;

  /// Available undo steps (overdub layers).
  final int undoDepth;

  /// Available redo steps.
  final int redoDepth;

  /// Track length in whole base loops (`>= 1`); `> 1` for a loop multiple.
  final int multiple;

  /// Lane 0's recorded input as a bitmask (`1 << inputChannel`, or `0` when
  /// lane 0 records no input). Mirrors lane 0; per-lane inputs are in [lanes].
  final int inputMask;

  /// Bitmask of hardware output channels this track plays to (bit c => out c).
  /// Mirrors lane 0.
  final int outputMask;

  /// The track's lanes, in lane order. Each records one input into its own
  /// clean buffer; empty in synthetic/default tracks.
  final List<Lane> lanes;

  /// Whether this track spans more than one base loop.
  bool get isMultiple => multiple > 1;

  /// Whether the track holds recorded audio.
  bool get hasContent => state != TrackState.empty && lengthFrames > 0;

  /// Whether the track is actively capturing (recording or overdubbing).
  bool get isCapturing =>
      state == TrackState.recording || state == TrackState.overdubbing;

  /// Whether an overdub layer can be undone.
  bool get canUndo => undoDepth > 0;

  /// Whether an undone overdub layer can be redone.
  bool get canRedo => redoDepth > 0;

  @override
  List<Object?> get props => [
    channel,
    state,
    volume,
    muted,
    lengthFrames,
    playheadFrames,
    rms,
    peak,
    undoDepth,
    redoDepth,
    multiple,
    inputMask,
    outputMask,
    lanes,
  ];
}
