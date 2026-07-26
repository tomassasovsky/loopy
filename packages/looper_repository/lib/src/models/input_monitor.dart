import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// The live-monitor configuration for one hardware input.
///
/// When [enabled], hardware input [input] is monitored live through
/// [preEffects] (prints into new takes) then [effects] / [postEffects]
/// (FOH/monitor colour only — never recorded). Routed to the outputs in
/// [outputMask], scaled by [volume] and gated by [muted].
///
/// Empty chains are the clean (dry) path. Pre/Post replace the old single-chain
/// "snapshot onto lane at record" model: Pre is the print path; Post stays live.
class InputMonitor extends Equatable {
  /// Creates an [InputMonitor].
  const InputMonitor({
    required this.input,
    this.enabled = false,
    this.outputMask = 0x3,
    this.volume = 1,
    this.muted = false,
    this.preEffects = const [],
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

  /// Input **Pre** chain — baked into recorded PCM. Empty = dry print.
  final List<TrackEffect> preEffects;

  /// Input **Post** chain — live/FOH colour only; never prints. Empty = dry
  /// monitor path. Kept as [effects] for existing callers; prefer
  /// [postEffects].
  final List<TrackEffect> effects;

  /// Alias for [effects] (Input Post).
  List<TrackEffect> get postEffects => effects;

  /// Returns a copy with the given fields replaced.
  InputMonitor copyWith({
    bool? enabled,
    int? outputMask,
    double? volume,
    bool? muted,
    List<TrackEffect>? preEffects,
    List<TrackEffect>? effects,
    List<TrackEffect>? postEffects,
  }) => InputMonitor(
    input: input,
    enabled: enabled ?? this.enabled,
    outputMask: outputMask ?? this.outputMask,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    preEffects: preEffects ?? this.preEffects,
    effects: postEffects ?? effects ?? this.effects,
  );

  @override
  List<Object?> get props => [
    input,
    enabled,
    outputMask,
    volume,
    muted,
    preEffects,
    effects,
  ];
}
