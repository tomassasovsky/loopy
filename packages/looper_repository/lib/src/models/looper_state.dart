import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/engine_status.dart';
import 'package:looper_repository/src/models/track.dart';
import 'package:looper_repository/src/models/transport_state.dart';

/// The single source of looper truth: transport, the tracks, and engine status,
/// projected from one engine snapshot.
class LooperState extends Equatable {
  /// Creates a [LooperState].
  const LooperState({
    this.transport = const TransportState(),
    this.tracks = const [],
    this.status = const EngineStatus(),
    this.outputEnabledMask = 0xFFFFFFFF,
  });

  /// Master loop transport.
  final TransportState transport;

  /// The looper tracks, indexed by channel.
  final List<Track> tracks;

  /// Device + engine health.
  final EngineStatus status;

  /// Structural output gate: bit c set => hardware output c is enabled (a
  /// routing target). A cleared bit removes that output from the mix while its
  /// stored route masks are preserved (re-enabling restores them). All outputs
  /// are enabled by default; only bits in `[0, status.outputChannels)` matter.
  final int outputEnabledMask;

  /// Whether hardware output [output] is currently enabled (a routing target).
  bool isOutputEnabled(int output) =>
      output < 0 || (outputEnabledMask & (1 << output)) != 0;

  /// The first track (back-compat convenience for single-track callers).
  Track get track => tracks.isNotEmpty ? tracks.first : const Track();

  /// Whether any track holds recorded audio.
  bool get hasContent => tracks.any((t) => t.hasContent);

  @override
  List<Object?> get props => [transport, tracks, status, outputEnabledMask];
}
