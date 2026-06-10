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

/// The record-source input bitmask changed on [channel].
final class LooperInputMaskChanged extends LooperChannelEvent {
  /// Creates a [LooperInputMaskChanged].
  const LooperInputMaskChanged(super.channel, this.mask);

  /// Bitmask of hardware input channels to record from (bit c => in c).
  final int mask;

  @override
  List<Object?> get props => [channel, mask];
}

/// The output-routing bitmask changed on [channel].
final class LooperOutputMaskChanged extends LooperChannelEvent {
  /// Creates a [LooperOutputMaskChanged].
  const LooperOutputMaskChanged(super.channel, this.mask);

  /// Bitmask of hardware output channels to play to (bit c => out c).
  final int mask;

  @override
  List<Object?> get props => [channel, mask];
}

/// Track [channel]'s quantize override changed: `null` inherits the global
/// default, `false` forces it off, `true` forces it on.
final class LooperTrackQuantizeChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackQuantizeChanged].
  const LooperTrackQuantizeChanged(super.channel, {required this.enabled});

  /// The override (`null` => inherit the global default).
  final bool? enabled;

  @override
  List<Object?> get props => [channel, enabled];
}

/// Track [channel]'s forced loop multiple changed (`0` = auto-round-up).
final class LooperTrackMultipleChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackMultipleChanged].
  const LooperTrackMultipleChanged(super.channel, this.multiple);

  /// The forced loop length in whole base loops, or `0` for auto.
  final int multiple;

  @override
  List<Object?> get props => [channel, multiple];
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

/// Clear every track that has content.
final class LooperClearAllPressed extends LooperEvent {
  /// Creates a [LooperClearAllPressed].
  const LooperClearAllPressed();
}
