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

/// Base for events targeting a single track [channel].
sealed class LooperChannelEvent extends LooperEvent {
  const LooperChannelEvent(this.channel);

  /// The target track channel.
  final int channel;

  @override
  List<Object?> get props => [channel];
}

/// The record/overdub control was pressed on [channel].
final class LooperRecordPressed extends LooperChannelEvent {
  /// Creates a [LooperRecordPressed].
  const LooperRecordPressed(super.channel);
}

/// The stop control was pressed on [channel].
final class LooperStopPressed extends LooperChannelEvent {
  /// Creates a [LooperStopPressed].
  const LooperStopPressed(super.channel);
}

/// The play control was pressed on [channel].
final class LooperPlayPressed extends LooperChannelEvent {
  /// Creates a [LooperPlayPressed].
  const LooperPlayPressed(super.channel);
}

/// The clear control was pressed on [channel].
final class LooperClearPressed extends LooperChannelEvent {
  /// Creates a [LooperClearPressed].
  const LooperClearPressed(super.channel);
}

/// The undo control was pressed on [channel].
final class LooperUndoPressed extends LooperChannelEvent {
  /// Creates a [LooperUndoPressed].
  const LooperUndoPressed(super.channel);
}

/// The redo control was pressed on [channel].
final class LooperRedoPressed extends LooperChannelEvent {
  /// Creates a [LooperRedoPressed].
  const LooperRedoPressed(super.channel);
}

/// The mute control was toggled on [channel].
final class LooperMuteToggled extends LooperChannelEvent {
  /// Creates a [LooperMuteToggled].
  const LooperMuteToggled(super.channel);
}

/// The track volume slider changed on [channel].
final class LooperVolumeChanged extends LooperChannelEvent {
  /// Creates a [LooperVolumeChanged].
  const LooperVolumeChanged(super.channel, this.volume);

  /// New gain in `0..1`.
  final double volume;

  @override
  List<Object?> get props => [channel, volume];
}

/// Play every track that has content.
final class LooperPlayAllPressed extends LooperEvent {
  /// Creates a [LooperPlayAllPressed].
  const LooperPlayAllPressed();
}

/// Stop every track.
final class LooperStopAllPressed extends LooperEvent {
  /// Creates a [LooperStopAllPressed].
  const LooperStopAllPressed();
}

/// The tempo was changed to [bpm].
final class LooperTempoChanged extends LooperEvent {
  /// Creates a [LooperTempoChanged].
  const LooperTempoChanged(this.bpm);

  /// New tempo in beats per minute.
  final double bpm;

  @override
  List<Object?> get props => [bpm];
}

/// The metronome was toggled.
final class LooperMetronomeToggled extends LooperEvent {
  /// Creates a [LooperMetronomeToggled].
  const LooperMetronomeToggled();
}

/// The count-in was toggled.
final class LooperCountInToggled extends LooperEvent {
  /// Creates a [LooperCountInToggled].
  const LooperCountInToggled();
}

/// A tempo tap was registered.
final class LooperTapTempo extends LooperEvent {
  /// Creates a [LooperTapTempo].
  const LooperTapTempo();
}
