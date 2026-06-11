import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// A single recordable lane within a `Track`.
///
/// A lane records exactly one hardware input ([inputChannel], `-1` = none) into
/// its own clean mono buffer and plays that buffer — through its own
/// non-destructive [effects] chain — to the outputs in [outputMask], scaled by
/// [volume] and gated by [muted]. Sibling lanes are never merged: a track with
/// two assigned inputs keeps both as separate lanes that play back together.
class Lane extends Equatable {
  /// Creates a [Lane].
  const Lane({
    this.inputChannel = -1,
    this.outputMask = 0x3,
    this.volume = 1,
    this.muted = false,
    this.lengthFrames = 0,
    this.rms = 0,
    this.peak = 0,
    this.effects = const [],
  });

  /// Hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  /// Bitmask of hardware output channels this lane plays to (bit c => out c).
  final int outputMask;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// Captured length of this lane's buffer in frames.
  final int lengthFrames;

  /// RMS level for the most recent block, in `0..1`.
  final double rms;

  /// Peak level for the most recent block, in `0..1`.
  final double peak;

  /// The lane's record-route effects chain, in processing order.
  final List<TrackEffect> effects;

  /// Whether the lane holds recorded audio.
  bool get hasContent => lengthFrames > 0;

  /// The recorded input as a bitmask (`1 << inputChannel`, or `0` when the lane
  /// records no input). Convenience for routing UIs that work in masks.
  int get inputMask => inputChannel >= 0 ? 1 << inputChannel : 0;

  @override
  List<Object?> get props => [
    inputChannel,
    outputMask,
    volume,
    muted,
    lengthFrames,
    rms,
    peak,
    effects,
  ];
}

/// The hardware input index of the lowest set bit in [mask], or `-1` when no
/// bit is set.
///
/// A lane records a single input, so the legacy mask-based routing UI maps a
/// selection mask to one lane input through this helper.
int maskToInputChannel(int mask) {
  if (mask == 0) return -1;
  for (var i = 0; i < 32; i++) {
    if (mask & (1 << i) != 0) return i;
  }
  return -1;
}
