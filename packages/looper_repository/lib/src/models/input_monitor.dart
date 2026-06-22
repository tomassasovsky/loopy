import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// A single live-monitor lane for one hardware input.
///
/// Mirrors `Lane` exactly, minus recording: a monitor lane carries the input's
/// live signal through its own non-destructive [effects] chain to the outputs
/// in [outputMask], scaled by [volume] and gated by [muted]. A lane with an
/// empty [effects] chain is the clean (dry) path — there is no special-case dry
/// concept. Sibling lanes are never merged; an input runs as many parallel
/// monitor paths as it has lanes.
class MonitorLane extends Equatable {
  /// Creates a [MonitorLane].
  const MonitorLane({
    this.outputMask = 0x3,
    this.volume = 1,
    this.muted = false,
    this.effects = const [],
  });

  /// Bitmask of hardware output channels this lane plays to (bit c => out c).
  final int outputMask;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// The lane's live effect chain, in processing order. Never recorded. An
  /// empty chain is the clean (dry) path.
  final List<TrackEffect> effects;

  /// Returns a copy with the given fields replaced.
  MonitorLane copyWith({
    int? outputMask,
    double? volume,
    bool? muted,
    List<TrackEffect>? effects,
  }) => MonitorLane(
    outputMask: outputMask ?? this.outputMask,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    effects: effects ?? this.effects,
  );

  @override
  List<Object?> get props => [outputMask, volume, muted, effects];
}

/// The live-monitor configuration for one hardware input.
///
/// When [enabled], hardware input [input] is monitored live across [lanes] —
/// each an independent parallel path with its own effect chain, output routing,
/// volume, and mute. This mirrors the multi-lane track model exactly, minus
/// recording: the monitored signal is never recorded and is independent of any
/// track's record/playback state. A lane with an empty effect chain is the
/// clean (dry) path, so "wet + dry" is simply an FX lane plus a no-FX lane.
class InputMonitor extends Equatable {
  /// Creates an [InputMonitor].
  const InputMonitor({
    required this.input,
    this.enabled = false,
    this.lanes = const [MonitorLane()],
  });

  /// The hardware input channel this monitor routes.
  final int input;

  /// Whether live monitoring of [input] is on (the input-level gate).
  final bool enabled;

  /// The input's parallel monitor lanes (always at least one).
  final List<MonitorLane> lanes;

  /// The active lane count (always `>= 1`).
  int get laneCount => lanes.isEmpty ? 1 : lanes.length;

  /// Lane [index], or a default [MonitorLane] when [index] is out of range.
  MonitorLane lane(int index) =>
      (index >= 0 && index < lanes.length) ? lanes[index] : const MonitorLane();

  /// Returns a copy with lane [index] replaced by [lane], rebuilding the list
  /// immutably (growing it with default lanes if [index] is just past the end).
  /// Callers never hand-roll list copies, keeping every lane edit race-free.
  InputMonitor withLane(int index, MonitorLane lane) {
    final next = List<MonitorLane>.of(lanes);
    while (next.length <= index) {
      next.add(const MonitorLane());
    }
    next[index] = lane;
    return copyWith(lanes: next);
  }

  /// Returns a copy with the given fields replaced.
  InputMonitor copyWith({
    bool? enabled,
    List<MonitorLane>? lanes,
  }) => InputMonitor(
    input: input,
    enabled: enabled ?? this.enabled,
    lanes: lanes ?? this.lanes,
  );

  @override
  List<Object?> get props => [input, enabled, lanes];
}
