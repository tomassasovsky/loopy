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

/// Base for events targeting one [lane] of a track [channel].
sealed class LooperLaneEvent extends LooperChannelEvent {
  const LooperLaneEvent(super.channel, this.lane);

  /// The target lane index within the track.
  final int lane;

  @override
  List<Object?> get props => [channel, lane];
}

/// Track [channel]'s active lane count changed (add/remove a lane). Lanes are a
/// stack: growing appends an empty lane, shrinking drops the last one.
final class LooperLaneCountChanged extends LooperChannelEvent {
  /// Creates a [LooperLaneCountChanged].
  const LooperLaneCountChanged(super.channel, this.count);

  /// The new active lane count (`>= 1`).
  final int count;

  @override
  List<Object?> get props => [channel, count];
}

/// Lane [lane] of track [channel] now records hardware input [inputChannel]
/// (`-1` records nothing). A lane captures a single clean input.
final class LooperLaneInputChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneInputChanged].
  const LooperLaneInputChanged(super.channel, super.lane, this.inputChannel);

  /// The hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  @override
  List<Object?> get props => [channel, lane, inputChannel];
}

/// Lane [lane] of track [channel]'s output-routing bitmask changed.
final class LooperLaneOutputChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneOutputChanged].
  const LooperLaneOutputChanged(super.channel, super.lane, this.mask);

  /// Bitmask of hardware output channels to play to (bit c => out c).
  final int mask;

  @override
  List<Object?> get props => [channel, lane, mask];
}

/// Lane [lane] of track [channel]'s playback volume changed.
final class LooperLaneVolumeChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneVolumeChanged].
  const LooperLaneVolumeChanged(super.channel, super.lane, this.volume);

  /// New gain in `0..1`.
  final double volume;

  @override
  List<Object?> get props => [channel, lane, volume];
}

/// Lane [lane] of track [channel]'s mute was toggled.
final class LooperLaneMuteToggled extends LooperLaneEvent {
  /// Creates a [LooperLaneMuteToggled].
  const LooperLaneMuteToggled(super.channel, super.lane);
}

/// Lane [lane] of track [channel]'s entire effect chain changed (a structural
/// edit: add, remove, reorder, or type). Resets the affected entries' DSP.
final class LooperLaneEffectsChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectsChanged].
  const LooperLaneEffectsChanged(super.channel, super.lane, this.effects);

  /// The new ordered chain (clamped to [kTrackEffectMax] downstream).
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [channel, lane, effects];
}

/// Parameter [param] of chain entry [index] on lane [lane] of track [channel]
/// changed to [value] (`0..1`). A live tweak — does not reset DSP state.
final class LooperLaneEffectParamChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectParamChanged].
  const LooperLaneEffectParamChanged(
    super.channel,
    super.lane,
    this.index,
    this.param,
    this.value,
  );

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The parameter index (`0..kTrackEffectParams-1`).
  final int param;

  /// The normalized parameter value (`0..1`).
  final double value;

  @override
  List<Object?> get props => [channel, lane, index, param, value];
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
