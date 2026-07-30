import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';

/// A scope-agnostic adapter over one editable FX chain, at any of the four FX
/// stages (R21): a hardware input's live-monitor chain ([InputFxScope]), a
/// recorded lane's snapshot ([LaneFxScope]), or a track's stereo bus / the
/// Master insert ([StageFxScope]). The FX editor drives a chain entirely
/// through this interface, so it never learns which bloc/cubit backs the chain.
///
/// A scope is a thin, **live** view: [effects] and [isPresent] re-read the
/// current state on every access (resolved off a stable identity — the
/// [address]), so the editor reflects external edits and can bail the moment
/// its target is gone. It is deliberately *not* a general chain-editor
/// framework — the surface is just this chain's fields and edits (mix lives on
/// the routing cards; the universal power controls are [setEffectEnabled] /
/// [setChainEnabled], never a plugin's own bypass parameter — D-POWER/R23).
abstract class FxScope {
  /// Const base constructor for the concrete scopes.
  const FxScope();

  /// Which chain this scope edits — stage + coordinates (A9/R19). Stage is
  /// data, not a type: the two bus stages share one [StageFxScope].
  FxAddress get address;

  /// The editor's title for this scope (e.g. `Input 1` / `Lane 1`).
  String label(AppLocalizations l10n);

  /// The plain-language consequence of editing here — the load-bearing bit of
  /// context (input FX "prints into new takes"; lane FX is non-destructive).
  String consequence(AppLocalizations l10n);

  /// The plain-language consequence of turning this whole chain OFF — what it
  /// does to what you hear, per stage (R15/R23).
  String chainDisabledConsequence(AppLocalizations l10n);

  /// Whether the scope's target still exists in the current state. A pushed
  /// editor route outlives its origin row, so it must bail when e.g. the lane
  /// it edits is removed while open.
  bool get isPresent;

  /// The chain in processing order, read live from the backing state. Empty
  /// when the target is gone (see [isPresent]).
  List<TrackEffect> get effects;

  /// Whether the WHOLE chain is engaged (R15). A disabled chain renders dry
  /// while every per-entry flag stays intact.
  bool get chainEnabled;

  /// Enables/disables chain entry [index] — the universal per-slot power
  /// control, identical for built-ins and hosted plugins (D-POWER, R23).
  void setEffectEnabled(int index, {required bool enabled});

  /// Enables/disables the whole chain in one atomic flip, leaving the
  /// per-entry flags untouched (R15).
  void setChainEnabled({required bool enabled});

  /// The hardware inputs this chain was copied from at record time, in input
  /// order (R13/A8); empty when the chain carries no inheritance marker. Only
  /// the loop stage can inherit — every other stage reports empty.
  List<int> get inheritedFrom => const [];

  /// Whether "re-sync from input" would copy anything: loop stage only, and
  /// only while the routed input actually carries an audible chain.
  bool get canResyncFromInput => false;

  /// Re-copies the routed input chain onto this chain **by value**, with a
  /// fresh provenance stamp (A6/R13). Explicit and user initiated — never
  /// automatic, and it never touches any other take. A no-op off the loop
  /// stage.
  void resyncFromInput() {}

  /// Whether this chain is being overdubbed onto while it no longer sounds
  /// like its routed input chain (A7) — an overdub never re-inherits, so the
  /// new layer is captured dry against a chain that has since drifted. Always
  /// false off the loop stage.
  bool get overdubMismatch => false;

  /// Whether another entry fits below the per-chain cap ([kTrackEffectMax]).
  bool get canAddEffect => effects.length < kTrackEffectMax;

  /// Appends a default (drive) built-in effect to the chain.
  void addEffect();

  /// Appends a built-in effect of [type] — the device browser's pick — as ONE
  /// intent per stage.
  ///
  /// Never composes an append with a retype: the index for that retype could
  /// only come from [effects], which is a projection that lags the backing
  /// store, so a chain that grew underneath the UI (a record-time snapshot
  /// copy, a re-sync) would make the retype land on an existing entry and
  /// silently reset it. Every stage carries the type on its own add event
  /// instead.
  void addEffectOfType(TrackEffectType type);

  /// Appends a hosted plugin identified by [ref] to the chain.
  void insertPlugin(PluginRef ref);

  /// Removes the chain entry at [index].
  void removeEffect(int index);

  /// Reorders the chain entry at [from] to [to] (the processing order is the
  /// signal order, so a move re-sequences the FX).
  void moveEffect(int from, int to);

  /// Retypes the built-in chain entry at [index] to [type].
  void setType(int index, TrackEffectType type);

  /// Sets the normalized (`0..1`) built-in parameter [param] of entry [index].
  void setParam(int index, int param, double value);

  /// Sets a hosted-plugin parameter (by stable id, plain value) on entry
  /// [index].
  void setPluginParam(int index, int paramId, double value);

  /// Opens the native editor window for the plugin chain entry at [index].
  void openPluginEditor(int index);

  /// Relinks the unavailable plugin chain entry at [index] to [ref] (D-MISS).
  void relinkPlugin(int index, PluginRef ref);

  /// The plugin's own display string for [value] on entry [index]'s parameter
  /// [paramId], or null when no live readout is available.
  String? formatPluginValue(int index, int paramId, double value);
}

/// The FX chain of a hardware input's **live monitor** — the tone that prints
/// into new takes at record. Backed by [MonitorCubit] (edits) and validated
/// against the engine's channel count from [LooperBloc]; a repository handle
/// serves the plugins' live value readouts.
class InputFxScope extends FxScope {
  /// Creates an [InputFxScope] for hardware input channel [input].
  const InputFxScope({
    required this.monitor,
    required this.looper,
    required this.repository,
    required this.input,
  });

  /// The monitor state + edit surface for the input chains.
  final MonitorCubit monitor;

  /// The engine status source, for validating the input still exists.
  final LooperBloc looper;

  /// The read-only handle for plugin value formatting.
  final LooperRepository repository;

  /// The hardware input channel this scope edits.
  final int input;

  @override
  FxAddress get address => FxAddress(stage: FxStage.input, index: input);

  @override
  String label(AppLocalizations l10n) => l10n.fxEditorInputTitle(input + 1);

  @override
  String consequence(AppLocalizations l10n) => l10n.fxEditorInputConsequence;

  @override
  String chainDisabledConsequence(AppLocalizations l10n) =>
      l10n.fxChainOffInputConsequence;

  @override
  bool get isPresent => input >= 0 && input < looper.state.status.inputChannels;

  @override
  List<TrackEffect> get effects =>
      isPresent ? monitor.state.forInput(input).effects : const [];

  @override
  bool get chainEnabled =>
      !isPresent || monitor.state.forInput(input).chainEnabled;

  @override
  void setEffectEnabled(int index, {required bool enabled}) =>
      monitor.setEffectEnabled(input, index, enabled: enabled);

  @override
  void setChainEnabled({required bool enabled}) =>
      monitor.setChainEnabled(input, enabled: enabled);

  @override
  void addEffect() => monitor.addEffect(input);

  @override
  void addEffectOfType(TrackEffectType type) =>
      monitor.addEffect(input, type: type);

  @override
  void insertPlugin(PluginRef ref) => monitor.insertPlugin(input, ref);

  @override
  void removeEffect(int index) => monitor.removeEffect(input, index);

  @override
  void moveEffect(int from, int to) => monitor.moveEffect(input, from, to);

  @override
  void setType(int index, TrackEffectType type) =>
      monitor.setEffectType(input, index, type);

  @override
  void setParam(int index, int param, double value) =>
      monitor.setEffectParam(input, index, param, value);

  @override
  void setPluginParam(int index, int paramId, double value) =>
      monitor.setPluginParam(input, index, paramId, value);

  @override
  void openPluginEditor(int index) => monitor.openPluginEditor(input, index);

  @override
  void relinkPlugin(int index, PluginRef ref) =>
      monitor.relinkPlugin(input, index, ref);

  @override
  String? formatPluginValue(int index, int paramId, double value) =>
      repository.monitorPluginParamText(
        input: input,
        index: index,
        paramId: paramId,
        value: value,
      );
}

/// The FX chain of a recorded **lane** — the non-destructive snapshot that
/// colours that take's playback. Backed by [LooperBloc], keyed by the stable
/// `(track, lane)` pair and re-validated against the live [LooperState] on each
/// access so a removed lane can never be edited through a stale index.
class LaneFxScope extends FxScope {
  /// Creates a [LaneFxScope] for lane [lane] of track [track].
  const LaneFxScope({
    required this.looper,
    required this.repository,
    required this.track,
    required this.lane,
  });

  /// The looper state + edit surface for the lane chains.
  final LooperBloc looper;

  /// The read-only handle for plugin value formatting.
  final LooperRepository repository;

  /// The track this lane belongs to.
  final int track;

  /// The lane index within the track.
  final int lane;

  @override
  FxAddress get address =>
      FxAddress(stage: FxStage.loop, index: track, lane: lane);

  @override
  String label(AppLocalizations l10n) => l10n.laneNumberLabel(lane + 1);

  @override
  String consequence(AppLocalizations l10n) => l10n.fxEditorLaneConsequence;

  @override
  String chainDisabledConsequence(AppLocalizations l10n) =>
      l10n.fxChainOffLoopConsequence;

  @override
  bool get isPresent {
    final tracks = looper.state.tracks;
    return track >= 0 &&
        track < tracks.length &&
        lane >= 0 &&
        lane < tracks[track].lanes.length;
  }

  /// The lane this scope edits, or null when its target is gone.
  Lane? get _lane => isPresent ? looper.state.tracks[track].lanes[lane] : null;

  @override
  List<TrackEffect> get effects => _lane?.effects ?? const [];

  @override
  bool get chainEnabled => _lane?.chainEnabled ?? true;

  @override
  List<int> get inheritedFrom => _lane?.inheritedFrom ?? const [];

  /// Read straight off the repository rather than off [LooperState], because
  /// the answer depends on the routed INPUT's chain, which no looper state
  /// object projects. Freshness is structural, not incidental: the only UI
  /// writer of an input chain is [MonitorCubit], and the FX dock watches it, so
  /// a monitor edit rebuilds this scope's reader in the same frame it emits.
  @override
  bool get canResyncFromInput =>
      isPresent && repository.laneCanInheritFromInput(track, lane);

  @override
  void resyncFromInput() =>
      looper.add(LooperLaneChainResyncedFromInput(track, lane));

  @override
  bool get overdubMismatch =>
      isPresent &&
      looper.state.tracks[track].state == TrackState.overdubbing &&
      (_lane?.inputChainDiverges ?? false);

  @override
  void setEffectEnabled(int index, {required bool enabled}) => looper.add(
    LooperLaneEffectEnabledToggled(track, lane, index, enabled: enabled),
  );

  @override
  void setChainEnabled({required bool enabled}) =>
      looper.add(LooperLaneChainEnabledToggled(track, lane, enabled: enabled));

  @override
  void addEffect() => looper.add(LooperLaneEffectAdded(track, lane));

  @override
  void addEffectOfType(TrackEffectType type) =>
      looper.add(LooperLaneEffectAdded(track, lane, type: type));

  @override
  void insertPlugin(PluginRef ref) =>
      looper.add(LooperLanePluginInserted(track, lane, ref));

  @override
  void removeEffect(int index) =>
      looper.add(LooperLaneEffectRemoved(track, lane, index));

  @override
  void moveEffect(int from, int to) =>
      looper.add(LooperLaneEffectMoved(track, lane, from, to));

  @override
  void setType(int index, TrackEffectType type) =>
      looper.add(LooperLaneEffectTypeChanged(track, lane, index, type));

  @override
  void setParam(int index, int param, double value) => looper.add(
    LooperLaneEffectParamChanged(track, lane, index, param, value),
  );

  @override
  void setPluginParam(int index, int paramId, double value) => looper.add(
    LooperLanePluginParamChanged(track, lane, index, paramId, value),
  );

  @override
  void openPluginEditor(int index) =>
      looper.add(LooperLanePluginEditorOpened(track, lane, index));

  @override
  void relinkPlugin(int index, PluginRef ref) =>
      looper.add(LooperLanePluginRelinked(track, lane, index, ref));

  @override
  String? formatPluginValue(int index, int paramId, double value) =>
      repository.lanePluginParamText(
        channel: track,
        lane: lane,
        index: index,
        paramId: paramId,
        value: value,
      );
}

/// The FX chain of a **bus stage** — a track's stereo bus ([FxStage.track],
/// downstream of that track's lanes) or the single Master insert
/// ([FxStage.master], on the summed mix before gain/limiter).
///
/// One scope covers both because the stage is *data* in [address], not a type:
/// the two differ only in which chain they read. Bus chains are owned by the
/// bloc (state, surgery, and persistence), so every edit here dispatches a
/// [LooperBusChainEvent] carrying INTENT — the bloc composes the next chain
/// from the repository while handling it. The scope never computes a chain
/// itself: reads come from [LooperState], which lags each write by the bloc's
/// async hop, so composing here would make two edits in one frame (the rack's
/// add-then-retype) clobber each other.
///
/// Hosted plugins have no bus-stage slot ABI yet: the domain preserves such an
/// entry but marks it unsupported, so it renders as a placeholder card rather
/// than controls. Hence no native editor and no live value readout here.
class StageFxScope extends FxScope {
  /// Creates a [StageFxScope] for the bus chain at [address], which must name
  /// a bus stage. Non-const (unlike its sibling scopes) because the guard reads
  /// `address.stage`, which is not a potentially-constant expression — and the
  /// guard THROWS rather than asserts, so an input/loop address cannot slip
  /// through a release build and silently edit a track's chain instead.
  StageFxScope({required this.looper, required this.address}) {
    if (address.stage != FxStage.track && address.stage != FxStage.master) {
      throw ArgumentError.value(
        address.stage,
        'address.stage',
        'StageFxScope covers the two bus stages; input/loop have their own',
      );
    }
  }

  /// The looper state + edit surface for the bus chains.
  final LooperBloc looper;

  @override
  final FxAddress address;

  /// Whether this scope edits the Master insert (else a track's stereo bus).
  bool get _isMaster => address.stage == FxStage.master;

  /// The track channel this scope edits (meaningless on the Master insert).
  int get _channel => address.index;

  @override
  String label(AppLocalizations l10n) => _isMaster
      ? l10n.fxEditorMasterTitle
      : l10n.fxEditorTrackTitle(_channel + 1);

  @override
  String consequence(AppLocalizations l10n) => _isMaster
      ? l10n.fxEditorMasterConsequence
      : l10n.fxEditorTrackConsequence;

  @override
  String chainDisabledConsequence(AppLocalizations l10n) => _isMaster
      ? l10n.fxChainOffMasterConsequence
      : l10n.fxChainOffTrackConsequence;

  @override
  bool get isPresent =>
      _isMaster || (_channel >= 0 && _channel < looper.state.tracks.length);

  @override
  List<TrackEffect> get effects {
    if (_isMaster) return looper.state.masterEffects;
    return isPresent ? looper.state.tracks[_channel].effects : const [];
  }

  @override
  bool get chainEnabled {
    if (_isMaster) return looper.state.masterChainEnabled;
    return !isPresent || looper.state.tracks[_channel].chainEnabled;
  }

  /// Dispatches a bus-stage edit intent for this scope's [address].
  void _edit(LooperBusChainEvent event) => looper.add(event);

  @override
  void addEffect() => _edit(LooperBusEffectAdded(address));

  @override
  void addEffectOfType(TrackEffectType type) =>
      _edit(LooperBusEffectAdded(address, type: type));

  @override
  void insertPlugin(PluginRef ref) =>
      _edit(LooperBusPluginInserted(address, ref));

  @override
  void removeEffect(int index) => _edit(LooperBusEffectRemoved(address, index));

  @override
  void moveEffect(int from, int to) =>
      _edit(LooperBusEffectMoved(address, from, to));

  @override
  void setType(int index, TrackEffectType type) =>
      _edit(LooperBusEffectTypeChanged(address, index, type));

  @override
  void setParam(int index, int param, double value) =>
      _edit(LooperBusEffectParamChanged(address, index, param, value));

  @override
  void setPluginParam(int index, int paramId, double value) =>
      _edit(LooperBusPluginParamChanged(address, index, paramId, value));

  @override
  void relinkPlugin(int index, PluginRef ref) =>
      _edit(LooperBusPluginRelinked(address, index, ref));

  @override
  void setEffectEnabled(int index, {required bool enabled}) => looper.add(
    _isMaster
        ? LooperMasterEffectEnabledToggled(index, enabled: enabled)
        : LooperTrackEffectEnabledToggled(_channel, index, enabled: enabled),
  );

  @override
  void setChainEnabled({required bool enabled}) => looper.add(
    _isMaster
        ? LooperMasterChainEnabledToggled(enabled: enabled)
        : LooperTrackChainEnabledToggled(_channel, enabled: enabled),
  );

  /// No-op: a bus-stage plugin never instantiates, so there is no native
  /// window to open (see the class doc).
  @override
  void openPluginEditor(int index) {}

  /// Null: no live bus-stage instance can format a value (see the class doc).
  @override
  String? formatPluginValue(int index, int paramId, double value) => null;
}
