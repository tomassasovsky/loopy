import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';

/// A scope-agnostic adapter over one editable FX chain — either a hardware
/// input's live-monitor chain ([InputFxScope]) or a recorded lane's snapshot
/// ([LaneFxScope]). The FX editor drives a chain entirely through this
/// interface, so it never learns which bloc/cubit backs the chain.
///
/// A scope is a thin, **live** view: [effects] and [isPresent] re-read the
/// current state on every access (resolved off a stable identity — the input
/// channel, or the `(track, lane)` pair), so the editor reflects external edits
/// and can bail the moment its target is gone. It is deliberately *not* a
/// general chain-editor framework — the surface is just this chain's fields and
/// edits (no mix, no bypass; those live elsewhere).
abstract class FxScope {
  /// Const base constructor for the concrete scopes.
  const FxScope();

  /// The editor's title for this scope (e.g. `Input 1` / `Lane 1`).
  String label(AppLocalizations l10n);

  /// The plain-language consequence of editing here — the load-bearing bit of
  /// context (input FX "prints into new takes"; lane FX is non-destructive).
  String consequence(AppLocalizations l10n);

  /// Whether the scope's target still exists in the current state. A pushed
  /// editor route outlives its origin row, so it must bail when e.g. the lane
  /// it edits is removed while open.
  bool get isPresent;

  /// The chain in processing order, read live from the backing state. Empty
  /// when the target is gone (see [isPresent]).
  List<TrackEffect> get effects;

  /// Whether another entry fits below the per-chain cap ([kTrackEffectMax]).
  bool get canAddEffect => effects.length < kTrackEffectMax;

  /// Appends a default (drive) built-in effect to the chain.
  void addEffect();

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
  String label(AppLocalizations l10n) => l10n.fxEditorInputTitle(input + 1);

  @override
  String consequence(AppLocalizations l10n) => l10n.fxEditorInputConsequence;

  @override
  bool get isPresent => input >= 0 && input < looper.state.status.inputChannels;

  @override
  List<TrackEffect> get effects =>
      isPresent ? monitor.state.forInput(input).effects : const [];

  @override
  void addEffect() => monitor.addEffect(input);

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
  String label(AppLocalizations l10n) => l10n.laneNumberLabel(lane + 1);

  @override
  String consequence(AppLocalizations l10n) => l10n.fxEditorLaneConsequence;

  @override
  bool get isPresent {
    final tracks = looper.state.tracks;
    return track >= 0 &&
        track < tracks.length &&
        lane >= 0 &&
        lane < tracks[track].lanes.length;
  }

  @override
  List<TrackEffect> get effects =>
      isPresent ? looper.state.tracks[track].lanes[lane].effects : const [];

  @override
  void addEffect() => looper.add(LooperLaneEffectAdded(track, lane));

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
