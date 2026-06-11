import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// The live-monitor configuration for one hardware input.
///
/// When [enabled], hardware input [input] is summed live to the outputs in
/// [outputMask] through its own [effects] chain. The monitored signal is never
/// recorded and is independent of any track's record/playback state — replacing
/// the old global monitor-FX bus and "monitor follows a track" model.
class InputMonitor extends Equatable {
  /// Creates an [InputMonitor].
  const InputMonitor({
    required this.input,
    this.enabled = false,
    this.outputMask = 0x3,
    this.dryOutputMask = 0,
    this.effects = const [],
  });

  /// The hardware input channel this monitor routes.
  final int input;

  /// Whether live monitoring of [input] is on.
  final bool enabled;

  /// Bitmask of hardware output channels the effected signal plays to
  /// (bit c => out c).
  final int outputMask;

  /// Bitmask of hardware output channels the CLEAN (pre-effects) signal plays
  /// to — a parallel dry send (`0` = off), so an input can be heard wet and dry
  /// at once on different outputs.
  final int dryOutputMask;

  /// The monitor's live effect chain, in processing order. Never recorded.
  final List<TrackEffect> effects;

  /// Returns a copy with the given fields replaced.
  InputMonitor copyWith({
    bool? enabled,
    int? outputMask,
    int? dryOutputMask,
    List<TrackEffect>? effects,
  }) => InputMonitor(
    input: input,
    enabled: enabled ?? this.enabled,
    outputMask: outputMask ?? this.outputMask,
    dryOutputMask: dryOutputMask ?? this.dryOutputMask,
    effects: effects ?? this.effects,
  );

  @override
  List<Object?> get props => [
    input,
    enabled,
    outputMask,
    dryOutputMask,
    effects,
  ];
}
