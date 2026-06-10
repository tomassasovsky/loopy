import 'package:equatable/equatable.dart';

/// The master loop transport (free mode: one master loop length, no tempo).
class TransportState extends Equatable {
  /// Creates a [TransportState].
  const TransportState({
    this.isRunning = false,
    this.masterLengthFrames = 0,
    this.masterPositionFrames = 0,
  });

  /// Whether the audio device is open and processing.
  final bool isRunning;

  /// Master loop length in frames; `0` before the first loop is finalized.
  final int masterLengthFrames;

  /// Current master loop playhead in frames.
  final int masterPositionFrames;

  /// Whether a master loop length has been established.
  bool get hasLoop => masterLengthFrames > 0;

  /// Normalized loop progress in `0..1`, or `0` when no loop exists.
  double get progress =>
      hasLoop ? masterPositionFrames / masterLengthFrames : 0;

  @override
  List<Object?> get props => [
    isRunning,
    masterLengthFrames,
    masterPositionFrames,
  ];
}
