import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:loopy_engine/loopy_engine.dart' show LaneCacheState;

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
    this.chainEnabled = true,
    this.inheritedFrom = const [],
    this.inputChainDiverges = false,
    this.cacheState,
  });

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

  /// The lane's record-route effects chain, in processing order.
  final List<TrackEffect> effects;

  /// Whether the lane's whole chain is engaged (R15/R18). Disabled == the lane
  /// plays dry while its per-entry flags stay intact.
  final bool chainEnabled;

  /// The inputs this lane's chain was inherited from at record time, in input
  /// order (R13/A8); empty when never inherited (or detached by part 4).
  final List<int> inheritedFrom;

  /// Whether the lane's chain currently differs (by sound fingerprint) from
  /// its routed input's monitor chain (A7) — the domain signal behind part 4's
  /// "input chain no longer matches this take" overdub hint.
  final bool inputChainDiverges;

  /// The lane's Loop-stage wet-cache state, or `null` when nobody is looking.
  ///
  /// Debug telemetry only (R27) — it says what the background renderer is
  /// doing, never anything about how the lane sounds ("when in doubt, play
  /// live"). Reading it from the engine costs a drain + scheduler pass per
  /// lane, so `LooperRepository.cacheTelemetryEnabled` gates it: `null` means
  /// telemetry is off and this lane was never polled, which is deliberately
  /// distinct from [LaneCacheState.live].
  final LaneCacheState? cacheState;

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
    chainEnabled,
    inheritedFrom,
    inputChainDiverges,
    cacheState,
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
