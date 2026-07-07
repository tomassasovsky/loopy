import 'package:loopy_engine/loopy_engine.dart';
import 'package:meta/meta.dart';

/// The state a performance-capture arm/disarm snapshot needs that the engine
/// snapshot alone cannot supply: lane + monitor effect chains, and the master
/// limiter (mirrors [AudioEngine]'s write-only surface for both — the
/// repository that owns the live chain/limiter cache hands them in, the same
/// way `session_repository`'s `SessionChains` works for session saves).
@immutable
class PerformanceChains {
  /// Creates a [PerformanceChains].
  const PerformanceChains({
    this.laneChains = const [],
    this.monitors = const [],
    this.limiterEnabled = false,
    this.limiterCeiling = 0.99,
  });

  /// The lane effect chains active at the moment of the snapshot.
  final List<PerformanceLaneChain> laneChains;

  /// The per-input monitor configurations active at the moment of the
  /// snapshot.
  final List<PerformanceMonitorState> monitors;

  /// Whether the master peak limiter is enabled.
  final bool limiterEnabled;

  /// The master peak limiter's ceiling (`0..1`), meaningful only when
  /// [limiterEnabled].
  final double limiterCeiling;
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
  });

  /// Track channel this chain belongs to.
  final int channel;

  /// Lane index within the track.
  final int lane;

  /// The chain's active entries, in order.
  final List<TrackEffect> effects;
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
  });

  /// Hardware input index.
  final int input;

  /// Whether live monitoring of the input is enabled.
  final bool enabled;

  /// Bitmask of output channels the monitor plays to.
  final int outputMask;

  /// Monitor output gain in `0..1`.
  final double volume;

  /// Whether the monitor is muted.
  final bool muted;

  /// The monitor chain's active entries, in order.
  final List<TrackEffect> effects;
}
