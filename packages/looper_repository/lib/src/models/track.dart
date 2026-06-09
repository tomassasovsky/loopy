import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// A single looper track: its state-machine phase, mix settings, and live
/// metering, as projected from the engine snapshot.
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
    this.inputChannel = 0,
    this.outputMask = 0x3,
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

  /// Hardware input channel this track records from.
  final int inputChannel;

  /// Bitmask of hardware output channels this track plays to (bit c => out c).
  final int outputMask;

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
    inputChannel,
    outputMask,
  ];
}
