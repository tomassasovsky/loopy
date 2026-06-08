import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/engine_status.dart';
import 'package:looper_repository/src/models/track.dart';
import 'package:looper_repository/src/models/transport_state.dart';

/// The single source of looper truth: transport, the track, and engine status,
/// projected from one engine snapshot.
class LooperState extends Equatable {
  /// Creates a [LooperState].
  const LooperState({
    this.transport = const TransportState(),
    this.track = const Track(),
    this.status = const EngineStatus(),
  });

  /// Master loop transport.
  final TransportState transport;

  /// The (single, Phase-2) track.
  final Track track;

  /// Device + engine health.
  final EngineStatus status;

  @override
  List<Object?> get props => [transport, track, status];
}
