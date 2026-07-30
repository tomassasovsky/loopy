import 'package:loopy_engine/loopy_engine.dart';
import 'package:meta/meta.dart';

/// The state a performance-capture arm/disarm snapshot needs that the engine
/// snapshot alone cannot supply: every FX stage's effect chains, and the master
/// limiter (mirrors [AudioEngine]'s write-only surface for both — the
/// repository that owns the live chain/limiter cache hands them in, the same
/// way `session_repository`'s `SessionChains` works for session saves).
///
/// All four stages of the FX v3 model are represented: Input ([monitors]),
/// Loop ([laneChains]), Track ([trackChains]) and Master ([masterEffects] +
/// [masterChainEnabled]). Every stage also carries its chain-enabled flag, and
/// each entry its own `enabled` bit, so a replay can seed arm-time bypass
/// state instead of guessing (R3).
@immutable
class PerformanceChains {
  /// Creates a [PerformanceChains].
  const PerformanceChains({
    this.laneChains = const [],
    this.monitors = const [],
    this.trackChains = const [],
    this.masterEffects = const [],
    this.masterChainEnabled = true,
    this.limiterEnabled = false,
    this.limiterCeiling = 0.99,
  });

  /// The Loop-stage (per-lane) effect chains active at the moment of the
  /// snapshot.
  final List<PerformanceLaneChain> laneChains;

  /// The Input-stage per-input monitor configurations active at the moment of
  /// the snapshot.
  final List<PerformanceMonitorState> monitors;

  /// The Track-stage (per-track stereo bus) chains active at the moment of the
  /// snapshot.
  final List<PerformanceTrackChain> trackChains;

  /// The Master insert chain's entries, in order (empty = no Master FX).
  final List<TrackEffect> masterEffects;

  /// Whether the Master insert chain is engaged as a whole.
  final bool masterChainEnabled;

  /// Whether the master peak limiter is enabled.
  final bool limiterEnabled;

  /// The master peak limiter's ceiling (`0..1`), meaningful only when
  /// [limiterEnabled].
  final double limiterCeiling;
}

/// One track's Track-stage (stereo bus) chain at the moment of a performance
/// snapshot.
///
/// Unlike the Loop stage — where the manifest's lane record also carries PCM,
/// length and the deferred flag, so the arm snapshot needs its own
/// `PerformanceLaneSnapshot` shape — a bus chain is nothing but its entries and
/// its flag. So this one class is BOTH the hand-in DTO and the manifest record,
/// and owns the JSON for it; there is no second near-identical shape to drift
/// from.
@immutable
class PerformanceTrackChain {
  /// Creates a [PerformanceTrackChain].
  const PerformanceTrackChain({
    required this.channel,
    this.effects = const [],
    this.chainEnabled = true,
  });

  /// Rebuilds a [PerformanceTrackChain] from a decoded JSON map. An absent
  /// `chainEnabled` reads as engaged, matching the writer's omit-when-default
  /// rule (and R15's "migration defaults every level to enabled").
  factory PerformanceTrackChain.fromJson(Map<String, dynamic> json) =>
      PerformanceTrackChain(
        channel: (json['channel'] as num).toInt(),
        chainEnabled: json['chainEnabled'] as bool? ?? true,
        effects: [
          for (final e in (json['effects'] as List<dynamic>? ?? const []))
            TrackEffect.fromJson(e as Map<String, dynamic>),
        ],
      );

  /// Track channel whose stereo bus this chain sits on.
  final int channel;

  /// The chain's entries, in order.
  final List<TrackEffect> effects;

  /// Whether the chain is engaged as a whole (R15).
  final bool chainEnabled;

  /// Serializes this chain to a JSON map, omitting both fields at their
  /// defaults so an all-default record stays minimal.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    if (!chainEnabled) 'chainEnabled': false,
    if (effects.isNotEmpty) 'effects': [for (final e in effects) e.toJson()],
  };
}

/// One lane's effect chain at the moment of a performance snapshot.
///
/// Stored structured (not an opaque encoded string, unlike
/// `session_repository`'s `SessionLaneChain`): the manifest's FX entries are a
/// canonical machine-readable record `daw_export` reads directly as plain
/// JSON, so each [TrackEffect.toJson] map is embedded as-is.
@immutable
class PerformanceLaneChain {
  /// Creates a [PerformanceLaneChain].
  const PerformanceLaneChain({
    required this.channel,
    required this.lane,
    required this.effects,
    this.chainEnabled = true,
  });

  /// Track channel this chain belongs to.
  final int channel;

  /// Lane index within the track.
  final int lane;

  /// The chain's entries, in order (each carrying its own `enabled` bit).
  final List<TrackEffect> effects;

  /// Whether the chain is engaged as a whole (R15).
  final bool chainEnabled;
}

/// One hardware input's live-monitor configuration at the moment of a
/// performance snapshot: routing/mix plus its effect chain.
@immutable
class PerformanceMonitorState {
  /// Creates a [PerformanceMonitorState].
  const PerformanceMonitorState({
    required this.input,
    required this.enabled,
    required this.outputMask,
    required this.volume,
    required this.muted,
    required this.effects,
    this.chainEnabled = true,
  });

  /// Hardware input index.
  final int input;

  /// Whether live monitoring of the input is enabled.
  final bool enabled;

  /// Bitmask of output channels the monitor plays to.
  final int outputMask;

  /// Monitor output gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above
  /// unity).
  final double volume;

  /// Whether the monitor is muted.
  final bool muted;

  /// The monitor chain's entries, in order (each carrying its own `enabled`
  /// bit).
  final List<TrackEffect> effects;

  /// Whether the monitor's chain is engaged as a whole (R15).
  final bool chainEnabled;
}
