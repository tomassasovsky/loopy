import 'package:equatable/equatable.dart';

/// The master loop transport plus tempo/metronome state.
class TransportState extends Equatable {
  /// Creates a [TransportState].
  const TransportState({
    this.isRunning = false,
    this.masterLengthFrames = 0,
    this.masterPositionFrames = 0,
    this.tempoBpm = 120,
    this.metronomeOn = false,
    this.countInEnabled = false,
    this.countingIn = false,
    this.currentBeat = 0,
  });

  /// Whether the audio device is open and processing.
  final bool isRunning;

  /// Master loop length in frames; `0` before the first loop is finalized.
  final int masterLengthFrames;

  /// Current master loop playhead in frames.
  final int masterPositionFrames;

  /// Tempo in beats per minute.
  final double tempoBpm;

  /// Whether the metronome click is enabled.
  final bool metronomeOn;

  /// Whether a count-in precedes the first recording.
  final bool countInEnabled;

  /// Whether a count-in is currently in progress.
  final bool countingIn;

  /// Current beat within the bar (`0..3`).
  final int currentBeat;

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
    tempoBpm,
    metronomeOn,
    countInEnabled,
    countingIn,
    currentBeat,
  ];
}
