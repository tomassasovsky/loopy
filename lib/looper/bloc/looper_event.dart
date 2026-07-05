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

/// A default effect (drive) was appended to lane [lane] of track [channel]'s
/// chain. A structural edit — the bloc reads the current chain and pushes the
/// grown one, so the view never computes the new list itself.
final class LooperLaneEffectAdded extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectAdded].
  const LooperLaneEffectAdded(super.channel, super.lane);
}

/// Chain entry [index] was removed from lane [lane] of track [channel].
final class LooperLaneEffectRemoved extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectRemoved].
  const LooperLaneEffectRemoved(super.channel, super.lane, this.index);

  /// The chain entry index to drop (`0..length-1`).
  final int index;

  @override
  List<Object?> get props => [channel, lane, index];
}

/// Chain entry [index] on lane [lane] of track [channel] became [type] (resets
/// that entry's DSP and seeds its default params).
final class LooperLaneEffectTypeChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectTypeChanged].
  const LooperLaneEffectTypeChanged(
    super.channel,
    super.lane,
    this.index,
    this.type,
  );

  /// The chain entry index to retype (`0..length-1`).
  final int index;

  /// The new effect type.
  final TrackEffectType type;

  @override
  List<Object?> get props => [channel, lane, index, type];
}

/// Chain entry [from] on lane [lane] of track [channel] was reordered to slot
/// [to].
final class LooperLaneEffectMoved extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectMoved].
  const LooperLaneEffectMoved(super.channel, super.lane, this.from, this.to);

  /// The entry's current index.
  final int from;

  /// The entry's target index.
  final int to;

  @override
  List<Object?> get props => [channel, lane, from, to];
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

/// Sets a hosted-plugin parameter on lane [lane]'s chain entry [index]. Unlike
/// [LooperLaneEffectParamChanged] (built-in, normalized + positional), this
/// addresses a parameter by its stable plugin [paramId] and carries a plain
/// (already-scaled) [value], routed to the plugin through the RT param queue.
final class LooperLanePluginParamChanged extends LooperLaneEvent {
  /// Creates a [LooperLanePluginParamChanged].
  const LooperLanePluginParamChanged(
    super.channel,
    super.lane,
    this.index,
    this.paramId,
    this.value,
  );

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The stable plugin parameter id (VST3 ParamID / CLAP clap_id).
  final int paramId;

  /// The plain (already-scaled) parameter value.
  final double value;

  @override
  List<Object?> get props => [channel, lane, index, paramId, value];
}

/// Appends a hosted plugin (identified by [ref]) to lane [lane]'s FX chain.
/// The repository loads it through the slot ABI on the next chain apply.
final class LooperLanePluginInserted extends LooperLaneEvent {
  /// Creates a [LooperLanePluginInserted].
  const LooperLanePluginInserted(super.channel, super.lane, this.ref);

  /// The identity of the plugin to insert (format + stable id + version).
  final PluginRef ref;

  @override
  List<Object?> get props => [channel, lane, ref];
}

/// Relinks lane [lane]'s plugin chain entry [index] to [ref] (umbrella D-MISS):
/// resolves an unavailable placeholder (or accepts a version change), keeping
/// the captured state + tweaks.
final class LooperLanePluginRelinked extends LooperLaneEvent {
  /// Creates a [LooperLanePluginRelinked].
  const LooperLanePluginRelinked(
    super.channel,
    super.lane,
    this.index,
    this.ref,
  );

  /// The chain entry index.
  final int index;

  /// The replacement plugin's identity.
  final PluginRef ref;

  @override
  List<Object?> get props => [channel, lane, index, ref];
}

/// Opens the native editor window for lane [lane]'s plugin chain entry [index]
/// (umbrella D-WIN). While open, the bloc polls the plugin (≤10 Hz) to mirror
/// editor-driven param moves onto the in-app knobs (D-SYNC).
final class LooperLanePluginEditorOpened extends LooperLaneEvent {
  /// Creates a [LooperLanePluginEditorOpened].
  const LooperLanePluginEditorOpened(super.channel, super.lane, this.index);

  /// The chain entry index.
  final int index;

  @override
  List<Object?> get props => [channel, lane, index];
}

/// Closes lane [lane]'s plugin chain entry [index] editor window and stops the
/// sync poll, with a final read-back of the plugin's params (D-SYNC).
final class LooperLanePluginEditorClosed extends LooperLaneEvent {
  /// Creates a [LooperLanePluginEditorClosed].
  const LooperLanePluginEditorClosed(super.channel, super.lane, this.index);

  /// The chain entry index.
  final int index;

  @override
  List<Object?> get props => [channel, lane, index];
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

/// Toggles the structural output gate for hardware [output] to [enabled]: a
/// disabled output is removed as a routing target (its lane/monitor masks are
/// preserved) and re-enabling restores them.
final class LooperOutputEnabledToggled extends LooperEvent {
  /// Creates a [LooperOutputEnabledToggled].
  const LooperOutputEnabledToggled(this.output, {required this.enabled});

  /// The hardware output channel index.
  final int output;

  /// Whether the output is a routing target.
  final bool enabled;

  @override
  List<Object?> get props => [output, enabled];
}
