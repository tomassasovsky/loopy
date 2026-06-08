part of 'duplex_smoke_cubit.dart';

/// Lifecycle status of the duplex passthrough smoke harness.
enum DuplexSmokeStatus {
  /// The engine is stopped.
  idle,

  /// The duplex device is open and audio is flowing.
  running,

  /// The engine failed to start.
  error,
}

/// State for the Phase-1 "hello duplex" smoke harness.
///
/// Surfaces the live [EngineSnapshot] plus a high-level [status] so the view
/// can prove the native engine runs duplex audio and measure round-trip
/// latency.
class DuplexSmokeState extends Equatable {
  /// Creates a [DuplexSmokeState].
  const DuplexSmokeState({
    this.status = DuplexSmokeStatus.idle,
    this.snapshot = const EngineSnapshot.initial(),
    this.deviceName = '',
    this.errorMessage,
  });

  /// High-level lifecycle status.
  final DuplexSmokeStatus status;

  /// The most recent engine snapshot (levels, latency, frame counters).
  final EngineSnapshot snapshot;

  /// The active device name, or empty when stopped.
  final String deviceName;

  /// A human-readable error when [status] is [DuplexSmokeStatus.error].
  final String? errorMessage;

  /// Returns a copy with the given fields replaced.
  DuplexSmokeState copyWith({
    DuplexSmokeStatus? status,
    EngineSnapshot? snapshot,
    String? deviceName,
    String? errorMessage,
  }) {
    return DuplexSmokeState(
      status: status ?? this.status,
      snapshot: snapshot ?? this.snapshot,
      deviceName: deviceName ?? this.deviceName,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [status, snapshot, deviceName, errorMessage];
}
