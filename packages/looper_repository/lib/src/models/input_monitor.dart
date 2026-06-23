import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// The live-monitor configuration for one hardware input.
///
/// When [enabled], hardware input [input] is monitored live through a single
/// non-destructive [effects] chain, routed to the outputs in [outputMask],
/// scaled by [volume] and gated by [muted]. An empty [effects] chain is the
/// clean (dry) path — there is no special-case dry concept. The monitored
/// signal is never recorded and is independent of any track's record/playback
/// state.
///
/// This single chain is what is **snapshot-copied** onto a track lane the
/// moment you record into [input]: the take plays back through the chain you
/// monitored, while the recorded buffer stays clean. The copy is by value, so
/// editing the input chain afterwards never alters an earlier take.
class InputMonitor extends Equatable {
  /// Creates an [InputMonitor].
  const InputMonitor({
    required this.input,
    this.enabled = false,
    this.outputMask = 0x3,
    this.volume = 1,
    this.muted = false,
    this.effects = const [],
  });

  /// The hardware input channel this monitor routes.
  final int input;

  /// Whether live monitoring of [input] is on (the input-level gate).
  final bool enabled;

  /// Bitmask of hardware output channels this monitor plays to (bit c => c).
  final int outputMask;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the monitor is muted.
  final bool muted;

  /// The input's live effect chain, in processing order. Never recorded; an
  /// empty chain is the clean (dry) path. Snapshot-copied to a lane on record.
  final List<TrackEffect> effects;

  /// Returns a copy with the given fields replaced.
  InputMonitor copyWith({
    bool? enabled,
    int? outputMask,
    double? volume,
    bool? muted,
    List<TrackEffect>? effects,
  }) => InputMonitor(
    input: input,
    enabled: enabled ?? this.enabled,
    outputMask: outputMask ?? this.outputMask,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    effects: effects ?? this.effects,
  );

  @override
  List<Object?> get props => [
    input,
    enabled,
    outputMask,
    volume,
    muted,
    effects,
  ];
}
