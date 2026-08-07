import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// What a hardware input's live monitor is asked to do.
///
/// Three states rather than two because a looper wants a middle one: you want
/// to hear yourself *into* a take without hearing the input over the loop
/// afterwards. [off] and [on] are unconditional; [auto] follows the record
/// arm, so the monitor opens when a track fed by this input arms and closes
/// when it stops.
///
/// This is **intent**, and it is what persists. The boolean the engine takes
/// is *reality*, resolved from this per the arm state — see
/// `LooperRepository.monitorResolved`.
enum MonitorMode {
  /// Never monitor this input.
  off,

  /// Monitor only while a track fed by this input is armed or capturing.
  auto,

  /// Always monitor this input.
  on,
}

/// The live-monitor configuration for one hardware input.
///
/// When [mode] opens the gate, hardware input [input] is monitored live
/// through a single
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
    this.mode = MonitorMode.off,
    this.outputMask = 0x3,
    this.volume = 1,
    this.muted = false,
    this.effects = const [],
    this.chainEnabled = true,
  });

  /// The hardware input channel this monitor routes.
  final int input;

  /// What this input's monitor is asked to do (the input-level gate). Intent,
  /// not reality: [MonitorMode.auto] resolves against the record arm.
  final MonitorMode mode;

  /// Bitmask of hardware output channels this monitor plays to (bit c => c).
  final int outputMask;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the monitor is muted.
  final bool muted;

  /// The input's live effect chain, in processing order. Never recorded; an
  /// empty chain is the clean (dry) path. Snapshot-copied to a lane on record.
  final List<TrackEffect> effects;

  /// Whether the whole chain is engaged (R15/R18). A chain-disabled monitor is
  /// treated as dry: it sounds dry live AND is never snapshot-copied onto a
  /// recording lane (D-CHAINDIS).
  final bool chainEnabled;

  /// Returns a copy with the given fields replaced.
  InputMonitor copyWith({
    MonitorMode? mode,
    int? outputMask,
    double? volume,
    bool? muted,
    List<TrackEffect>? effects,
    bool? chainEnabled,
  }) => InputMonitor(
    input: input,
    mode: mode ?? this.mode,
    outputMask: outputMask ?? this.outputMask,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    effects: effects ?? this.effects,
    chainEnabled: chainEnabled ?? this.chainEnabled,
  );

  @override
  List<Object?> get props => [
    input,
    mode,
    outputMask,
    volume,
    muted,
    effects,
    chainEnabled,
  ];
}
