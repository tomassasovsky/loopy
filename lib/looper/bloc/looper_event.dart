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

  /// New gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
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

/// Track [channel]'s length preset changed (A6, D17; `0` = AUTO).
///
/// Governs the DEFINING (first/master) recording only — orthogonal to
/// [LooperTrackMultipleChanged], which governs a non-defining track once a
/// master already exists.
final class LooperTrackLengthPresetChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackLengthPresetChanged].
  const LooperTrackLengthPresetChanged(super.channel, this.bars);

  /// The fixed bar count, or `0` for AUTO.
  final int bars;

  @override
  List<Object?> get props => [channel, bars];
}

/// Track [channel]'s One Shot flag changed (song-mode-spec.md §2, B5c):
/// `true` = the track plays once and then stops instead of looping.
/// Settable in any looper mode, but only behaviorally active in Free/Song.
final class LooperOneShotToggled extends LooperChannelEvent {
  /// Creates a [LooperOneShotToggled].
  const LooperOneShotToggled(super.channel, {required this.oneShot});

  /// The new flag value.
  final bool oneShot;

  @override
  List<Object?> get props => [channel, oneShot];
}

/// Every track's one-shot flag was set to [oneShot] at once — the rig-wide
/// switch on the console's Mode face.
///
/// One event rather than the UI fanning out a [LooperOneShotToggled] per
/// track: the rig-wide rule is then written down once, where it can be tested
/// without a widget, and a half-applied sweep cannot be observed between two
/// dispatches.
final class LooperAllOneShotToggled extends LooperEvent {
  /// Creates a [LooperAllOneShotToggled].
  const LooperAllOneShotToggled({required this.oneShot});

  /// The new flag, applied to every track.
  final bool oneShot;

  @override
  List<Object?> get props => [oneShot];
}

/// [channel] was crowned the primary track (Sync/Band, D18;
/// `crownPrimary` — D20). No "un-crown" event exists — the only way to move
/// the crown is to crown a different channel.
final class LooperCrownPrimaryPressed extends LooperChannelEvent {
  /// Creates a [LooperCrownPrimaryPressed].
  const LooperCrownPrimaryPressed(super.channel);
}

/// The five-mode axis (Multi/Sync/Song/Band/Free) changed (D4). The UI is
/// responsible for the D4 clear-all confirmation BEFORE dispatching this —
/// the engine silently ignores the change while any track has content (see
/// `LooperModeControl.setLooperMode`'s doc), so this event assumes the
/// caller has already confirmed/cleared.
final class LooperModeChanged extends LooperEvent {
  /// Creates a [LooperModeChanged].
  const LooperModeChanged(this.mode);

  /// The new looper mode.
  final LooperMode mode;

  @override
  List<Object?> get props => [mode];
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

  /// New gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
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
  /// Creates a [LooperLaneEffectAdded]; [type] defaults to drive.
  const LooperLaneEffectAdded(super.channel, super.lane, {this.type});

  /// The device type to add, carried so add-of-type is ONE intent — the UI
  /// never has to name the new entry's index, which it could only read from a
  /// projection that lags this write.
  final TrackEffectType? type;

  @override
  List<Object?> get props => [channel, lane, type];
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

/// Entry [index] of lane [lane] of track [channel]'s chain was toggled to
/// [enabled] — the loop-stage twin of [LooperTrackEffectEnabledToggled]
/// (per-slot flag; click-free ramp engine-side).
final class LooperLaneEffectEnabledToggled extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectEnabledToggled].
  const LooperLaneEffectEnabledToggled(
    super.channel,
    super.lane,
    this.index, {
    required this.enabled,
  });

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [channel, lane, index, enabled];
}

/// Lane [lane] of track [channel]'s WHOLE chain was toggled to [enabled] in
/// one atomic flip (per-entry flags untouched).
final class LooperLaneChainEnabledToggled extends LooperLaneEvent {
  /// Creates a [LooperLaneChainEnabledToggled].
  const LooperLaneChainEnabledToggled(
    super.channel,
    super.lane, {
    required this.enabled,
  });

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [channel, lane, enabled];
}

/// Re-copies lane [lane] of track [channel]'s routed input chain onto the lane
/// by value, with a fresh provenance stamp (A6/R13). Explicit and user
/// initiated — inheritance is never automatic, and an overdub never
/// re-inherits (A7).
final class LooperLaneChainResyncedFromInput extends LooperLaneEvent {
  /// Creates a [LooperLaneChainResyncedFromInput].
  const LooperLaneChainResyncedFromInput(super.channel, super.lane);
}

/// Base for the **bus-stage** chain edits — the Track stereo bus and the
/// Master insert — addressed by [FxAddress] rather than by a stage-specific
/// event pair, since the stage is data (A9/R19) and the two differ only in
/// which chain the handler reads and writes.
///
/// Every one of these carries an *intent*, never a computed chain: the bloc
/// composes the next list from the repository's current chain while it handles
/// the event. Composing in the UI instead would read `LooperState`, which lags
/// each write by the bloc's async hop, so two edits dispatched in one frame
/// (the rack's add-then-retype) would collapse into one.
sealed class LooperBusChainEvent extends LooperEvent {
  /// Creates a [LooperBusChainEvent] for the chain at [address].
  const LooperBusChainEvent(this.address);

  /// The bus chain being edited ([FxStage.track] or [FxStage.master]).
  final FxAddress address;

  @override
  List<Object?> get props => [address];
}

/// Appends a built-in effect to the bus chain at [address]. [type] carries the
/// device browser's pick, so add-of-type is ONE intent rather than an append
/// followed by a retype of an index the UI had to guess.
final class LooperBusEffectAdded extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectAdded]; [type] defaults to drive.
  const LooperBusEffectAdded(super.address, {this.type});

  /// The device type to add, or null for the default (drive).
  final TrackEffectType? type;

  @override
  List<Object?> get props => [address, type];
}

/// Removes entry [index] from the bus chain at [address].
final class LooperBusEffectRemoved extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectRemoved].
  const LooperBusEffectRemoved(super.address, this.index);

  /// The chain entry index.
  final int index;

  @override
  List<Object?> get props => [address, index];
}

/// Moves entry [from] to [to] in the bus chain at [address] (the processing
/// order is the signal order, so a move re-sequences the FX).
final class LooperBusEffectMoved extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectMoved].
  const LooperBusEffectMoved(super.address, this.from, this.to);

  /// The entry's current index.
  final int from;

  /// The post-removal target index.
  final int to;

  @override
  List<Object?> get props => [address, from, to];
}

/// Retypes built-in entry [index] of the bus chain at [address] to [type]
/// (resets its DSP state and seeds default params).
final class LooperBusEffectTypeChanged extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectTypeChanged].
  const LooperBusEffectTypeChanged(super.address, this.index, this.type);

  /// The chain entry index.
  final int index;

  /// The new device type.
  final TrackEffectType type;

  @override
  List<Object?> get props => [address, index, type];
}

/// Sets built-in parameter [param] of entry [index] of the bus chain at
/// [address] to the normalized [value], without a structural reset.
final class LooperBusEffectParamChanged extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectParamChanged].
  const LooperBusEffectParamChanged(
    super.address,
    this.index,
    this.param,
    this.value,
  );

  /// The chain entry index.
  final int index;

  /// The positional built-in parameter index.
  final int param;

  /// The new normalized (`0..1`) value.
  final double value;

  @override
  List<Object?> get props => [address, index, param, value];
}

/// Appends the hosted plugin [ref] to the bus chain at [address]. The domain
/// preserves the entry but marks it unsupported until a bus-stage slot ABI
/// lands, so it renders as a placeholder rather than as controls.
final class LooperBusPluginInserted extends LooperBusChainEvent {
  /// Creates a [LooperBusPluginInserted].
  const LooperBusPluginInserted(super.address, this.ref);

  /// The plugin's identity.
  final PluginRef ref;

  @override
  List<Object?> get props => [address, ref];
}

/// Sets hosted-plugin parameter [paramId] of entry [index] of the bus chain at
/// [address] to the plain [value].
final class LooperBusPluginParamChanged extends LooperBusChainEvent {
  /// Creates a [LooperBusPluginParamChanged].
  const LooperBusPluginParamChanged(
    super.address,
    this.index,
    this.paramId,
    this.value,
  );

  /// The chain entry index.
  final int index;

  /// The stable plugin parameter id.
  final int paramId;

  /// The plain (already-scaled) parameter value.
  final double value;

  @override
  List<Object?> get props => [address, index, paramId, value];
}

/// Relinks plugin entry [index] of the bus chain at [address] to [ref].
final class LooperBusPluginRelinked extends LooperBusChainEvent {
  /// Creates a [LooperBusPluginRelinked].
  const LooperBusPluginRelinked(super.address, this.index, this.ref);

  /// The chain entry index.
  final int index;

  /// The replacement plugin's identity.
  final PluginRef ref;

  @override
  List<Object?> get props => [address, index, ref];
}

/// Track [channel]'s Track-stage (stereo bus) chain was replaced with
/// [effects] — the bus twin of the lane chain-set path (FX v3 part 3a). The
/// bloc owns Track/Master chain state: it pushes through the repository and
/// persists the encoded envelope.
final class LooperTrackEffectsChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackEffectsChanged].
  const LooperTrackEffectsChanged(super.channel, this.effects);

  /// The new chain, in processing order.
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [channel, effects];
}

/// Entry [index] of track [channel]'s Track-stage chain was toggled to
/// [enabled] (per-slot flag; click-free ramp engine-side).
final class LooperTrackEffectEnabledToggled extends LooperChannelEvent {
  /// Creates a [LooperTrackEffectEnabledToggled].
  const LooperTrackEffectEnabledToggled(
    super.channel,
    this.index, {
    required this.enabled,
  });

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [channel, index, enabled];
}

/// Track [channel]'s WHOLE Track-stage chain was toggled to [enabled] in one
/// atomic flip (per-entry flags untouched).
final class LooperTrackChainEnabledToggled extends LooperChannelEvent {
  /// Creates a [LooperTrackChainEnabledToggled].
  const LooperTrackChainEnabledToggled(super.channel, {required this.enabled});

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [channel, enabled];
}

/// Track [channel]'s Track-stage chain was FLIPPED — the relative twin of
/// [LooperTrackChainEnabledToggled], mirroring [LooperMuteToggled].
///
/// The surfaces that toggle rather than set (the tracks tiles, the number
/// keys) must not compute the new value themselves: their only reading of the
/// flag is the ~16 ms-polled `LooperState`, which is missing entirely before
/// the engine publishes tracks and stale for a poll after any other surface
/// flips the same chain. The handler resolves it against the repository's
/// remembered intent instead, so every surface agrees on what "the other way"
/// means.
final class LooperTrackChainToggled extends LooperChannelEvent {
  /// Creates a [LooperTrackChainToggled].
  const LooperTrackChainToggled(super.channel);
}

/// The Master insert chain was replaced with [effects].
final class LooperMasterEffectsChanged extends LooperEvent {
  /// Creates a [LooperMasterEffectsChanged].
  const LooperMasterEffectsChanged(this.effects);

  /// The new chain, in processing order.
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [effects];
}

/// Entry [index] of the Master insert chain was toggled to [enabled].
final class LooperMasterEffectEnabledToggled extends LooperEvent {
  /// Creates a [LooperMasterEffectEnabledToggled].
  const LooperMasterEffectEnabledToggled(this.index, {required this.enabled});

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [index, enabled];
}

/// The WHOLE Master insert chain was toggled to [enabled] in one atomic flip.
final class LooperMasterChainEnabledToggled extends LooperEvent {
  /// Creates a [LooperMasterChainEnabledToggled].
  const LooperMasterChainEnabledToggled({required this.enabled});

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [enabled];
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

/// A session load landed, so the bloc must write its chains back to the
/// boot-restore keys — see `_resyncSessionChains`.
///
/// Named for the trigger rather than the work, like every other event here: a
/// load is what HAPPENED; re-persisting is this bloc's response to it.
final class LooperSessionLoaded extends LooperEvent {
  /// Creates a [LooperSessionLoaded].
  const LooperSessionLoaded();
}
