part of 'looper_bloc.dart';

/// Base type for [LooperBloc] events.
sealed class LooperEvent extends Equatable {
  const LooperEvent();

  @override
  List<Object?> get props => [];
}

/// Internal: a new [LooperState] arrived from the repository stream.
final class LooperStateUpdated extends LooperEvent {
  /// Creates a [LooperStateUpdated].
  const LooperStateUpdated(this.state);

  /// The latest projected looper state.
  final LooperState state;

  @override
  List<Object?> get props => [state];
}

/// The record/overdub control was pressed.
final class LooperRecordPressed extends LooperEvent {
  /// Creates a [LooperRecordPressed].
  const LooperRecordPressed();
}

/// The stop control was pressed.
final class LooperStopPressed extends LooperEvent {
  /// Creates a [LooperStopPressed].
  const LooperStopPressed();
}

/// The play control was pressed.
final class LooperPlayPressed extends LooperEvent {
  /// Creates a [LooperPlayPressed].
  const LooperPlayPressed();
}

/// The clear control was pressed.
final class LooperClearPressed extends LooperEvent {
  /// Creates a [LooperClearPressed].
  const LooperClearPressed();
}

/// The undo control was pressed.
final class LooperUndoPressed extends LooperEvent {
  /// Creates a [LooperUndoPressed].
  const LooperUndoPressed();
}

/// The track volume slider changed.
final class LooperVolumeChanged extends LooperEvent {
  /// Creates a [LooperVolumeChanged].
  const LooperVolumeChanged(this.volume);

  /// New gain in `0..1`.
  final double volume;

  @override
  List<Object?> get props => [volume];
}

/// The mute control was toggled.
final class LooperMuteToggled extends LooperEvent {
  /// Creates a [LooperMuteToggled].
  const LooperMuteToggled();
}
