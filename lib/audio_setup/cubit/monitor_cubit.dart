import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Per-hardware-input live-monitor configuration.
///
/// Each monitored input carries its live signal through a single effect chain
/// with its own output routing, volume, and mute. An empty effect chain is the
/// clean (dry) path. This is the chain snapshot-copied onto a track lane
/// when you record into the input, so what you monitor is what the take stores.
class MonitorState extends Equatable {
  /// Creates a [MonitorState] from a map of input index to its [InputMonitor].
  const MonitorState({this.inputs = const {}});

  /// The configured monitors, keyed by hardware input index. Inputs absent from
  /// the map are not monitored (a default, disabled [InputMonitor]).
  final Map<int, InputMonitor> inputs;

  /// The monitor for [input], or a disabled default when none is configured.
  InputMonitor forInput(int input) =>
      inputs[input] ?? InputMonitor(input: input);

  /// Whether [input] has a configured monitor, as opposed to the synthesized
  /// default [forInput] hands back. Callers that WRITE must check this first,
  /// or they materialize (and persist) a monitor the user never created.
  bool hasInput(int input) => inputs.containsKey(input);

  /// Returns a copy with [monitor] replacing its input's entry.
  MonitorState withInput(InputMonitor monitor) =>
      MonitorState(inputs: {...inputs, monitor.input: monitor});

  @override
  List<Object?> get props => [inputs];
}

/// Owns the per-input live monitors: applies them to the [LooperRepository] and
/// persists them via [SettingsRepository].
class MonitorCubit extends Cubit<MonitorState> {
  /// Creates a [MonitorCubit] driving [repository], persisted through
  /// [settings].
  MonitorCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const MonitorState());

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// The inbound editor-sync poll cadence (D-SYNC: ≤10 Hz).
  static const Duration _editorPollInterval = Duration(milliseconds: 100);

  /// Per-open-editor sync poll timers, keyed by `(input, index)`. Cancelled on
  /// close / [close] so a closed editor never leaves a ticking timer.
  final Map<(int, int), Timer> _editorTimers = {};

  /// Restores the persisted per-input monitors and applies them to the
  /// repository. Reads the single-chain keys; the multi-lane → single-chain
  /// fold (v3) runs at bootstrap, before this.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    // Scan the shared engine input ceiling ([kMaxInputs] == `LE_MAX_INPUTS`).
    // Only inputs with saved state populate the map.
    final loaded = await Future.wait([
      for (var input = 0; input < kMaxInputs; input++) _restoreInput(input),
    ]);
    if (isClosed) return;
    final restored = <int, InputMonitor>{};
    for (final monitor in loaded) {
      if (monitor != null) restored[monitor.input] = monitor;
    }
    emit(MonitorState(inputs: restored));
    restored.values.forEach(_applyMonitor);
    // Mint-once for legacy payloads (A9): the repository minted stable slot
    // ids for any id-less restored entries while the chains were applied
    // above. Re-read the minted chains into state and persist them back, or
    // every launch would re-mint DIFFERENT ids for the same legacy chain.
    for (final monitor in restored.values) {
      if (isClosed) return;
      if (!monitor.effects.any((fx) => fx.slotId == null)) continue;
      final minted = _repository.monitorEffects(monitor.input);
      // Nothing applied (engine not running / a unit-test fake): keep the
      // un-minted state; the next real apply re-mints and persists.
      if (minted.isEmpty) continue;
      emit(state.withInput(monitor.copyWith(effects: minted)));
      await _settings.saveMonitorEffects(
        monitor.input,
        _encodedChain(monitor.input, minted),
      );
    }
  }

  /// Maps a persisted mode name back to the enum. An unrecognised name reads
  /// as `null` — "nothing saved" — rather than silently becoming `off`, so a
  /// key written by a future build is not mistaken for a deliberate disable.
  static MonitorMode? _modeFromName(String? name) {
    for (final mode in MonitorMode.values) {
      if (mode.name == name) return mode;
    }
    return null;
  }

  /// Reads hardware [input]'s persisted single-chain monitor, or null if none
  /// was saved. The chain key holds the envelope (R15) — the chain-enabled
  /// flag rides inside it; a legacy bare-array chain decodes chain-enabled.
  Future<InputMonitor?> _restoreInput(int input) async {
    final mode = _modeFromName(await _settings.loadMonitorInputMode(input));
    final outputMask = await _settings.loadMonitorOutput(input);
    final volume = await _settings.loadMonitorVolume(input);
    final muted = await _settings.loadMonitorMute(input);
    final encodedChain = await _settings.loadMonitorEffects(input);
    final chain = decodeFxChain(encodedChain);
    // A chain-DISABLED envelope counts as saved state even with no entries:
    // the encode side can write {chainEnabled:false, entries:[]} (disable the
    // chain, then remove its last effect), and dropping it here would revert
    // the flag to enabled on the next boot — the disable-survives-restart
    // guarantee R15 pins.
    final anySaved =
        mode != null ||
        outputMask != null ||
        volume != null ||
        muted != null ||
        chain.entries.isNotEmpty ||
        !chain.chainEnabled;
    if (!anySaved) return null;
    return InputMonitor(
      input: input,
      mode: mode ?? MonitorMode.off,
      outputMask: outputMask ?? 0x3,
      volume: volume ?? 1.0,
      muted: muted ?? false,
      effects: chain.entries,
      chainEnabled: chain.chainEnabled,
    );
  }

  /// Re-projects the per-input monitors from the [LooperRepository] (the single
  /// owner) after a session load applied them straight to the engine, past this
  /// cubit. Without this the dock would keep showing the PREVIOUS session's
  /// monitors and re-apply them on the next edit, and the persisted settings
  /// would drift from the loaded session (a wrong boot restore).
  ///
  /// Re-persists every configured monitor and resets inputs dropped since the
  /// last state to the disabled default — the same value-level reset
  /// `LooperRepository.applySession` applies to undefined monitors, so the next
  /// boot restores an inert (disabled, unrouted-to-nothing) monitor rather than
  /// the pre-load leftover. Reads only from the repository; never re-applies to
  /// the engine (the load already did), so it cannot desync engine vs cache.
  Future<void> syncFromRepository() async {
    final applied = _repository.allMonitors();
    final dropped = state.inputs.keys
        .where((input) => !applied.containsKey(input))
        .toList();
    // Any open editor-sync poll is keyed to a chain index the load reseated.
    state.inputs.keys.forEach(_cancelEditorTimers);
    emit(MonitorState(inputs: applied));
    await Future.wait([
      for (final monitor in applied.values) _persistMonitor(monitor),
      for (final input in dropped) _persistMonitor(InputMonitor(input: input)),
    ]);
  }

  /// Persists every field of [monitor] (the five monitor settings keys). Shared
  /// by [syncFromRepository]'s apply + reset paths so they never diverge from
  /// the set of persisted fields.
  Future<void> _persistMonitor(InputMonitor monitor) async {
    await _settings.saveMonitorInputMode(
      monitor.input,
      mode: monitor.mode.name,
    );
    await _settings.saveMonitorOutput(monitor.input, monitor.outputMask);
    await _settings.saveMonitorVolume(monitor.input, monitor.volume);
    await _settings.saveMonitorMute(monitor.input, muted: monitor.muted);
    await _settings.saveMonitorEffects(
      monitor.input,
      encodeFxChain(
        FxChainEnvelope(
          chainEnabled: monitor.chainEnabled,
          entries: monitor.effects,
        ),
      ),
    );
  }

  /// Enables or disables monitoring of hardware [input], applying and
  /// persisting the change.
  Future<void> setMode(int input, MonitorMode mode) async {
    final monitor = state.forInput(input).copyWith(mode: mode);
    emit(state.withInput(monitor));
    _repository.setMonitorInputMode(input: input, mode: mode);
    await _settings.saveMonitorInputMode(input, mode: mode.name);
  }

  /// Sets and persists monitor [input]'s output bitmask.
  Future<void> setOutputMask(int input, int mask) async {
    final next = state.forInput(input).copyWith(outputMask: mask);
    emit(state.withInput(next));
    _repository.setMonitorOutput(input: input, mask: mask);
    await _settings.saveMonitorOutput(input, mask);
  }

  /// Sets and persists monitor [input]'s output gain (`0..LE_MAX_GAIN`, 2.0,
  /// +6.02 dB headroom above unity).
  Future<void> setVolume(int input, double volume) async {
    final next = state.forInput(input).copyWith(volume: volume);
    emit(state.withInput(next));
    _repository.setMonitorVolume(input: input, volume: volume);
    await _settings.saveMonitorVolume(input, volume);
  }

  /// Mutes or unmutes monitor [input].
  Future<void> setMute(int input, {required bool muted}) async {
    final next = state.forInput(input).copyWith(muted: muted);
    emit(state.withInput(next));
    _repository.setMonitorMute(input: input, muted: muted);
    await _settings.saveMonitorMute(input, muted: muted);
  }

  /// Appends a default effect (drive) to monitor [input]'s chain.
  void addEffect(int input, {TrackEffectType? type}) {
    final effects = state.forInput(input).effects;
    _pushEffects(input, [
      ...effects,
      BuiltInEffect(type: type ?? TrackEffectType.drive),
    ]);
  }

  /// Appends a hosted plugin (identified by [ref]) to monitor [input]'s chain.
  /// The repository loads it through the slot ABI on the next chain apply.
  void insertPlugin(int input, PluginRef ref) {
    _pushEffects(input, [
      ...state.forInput(input).effects,
      PluginEffect(ref: ref),
    ]);
  }

  /// Relinks monitor [input]'s plugin chain entry [index] to [ref] (D-MISS),
  /// keeping its captured state + tweaks.
  void relinkPlugin(int input, int index, PluginRef ref) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    final fx = monitor.effects[index];
    if (fx is! PluginEffect) return;
    _repository.relinkMonitorPlugin(input: input, index: index, ref: ref);
    final applied = _repository.monitorEffects(input);
    emit(state.withInput(monitor.copyWith(effects: applied)));
    unawaited(
      _settings.saveMonitorEffects(input, _encodedChain(input, applied)),
    );
  }

  /// Removes monitor [input]'s chain entry at [index].
  void removeEffect(int input, int index) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    _pushEffects(input, [...effects]..removeAt(index));
  }

  /// Reorders monitor [input]'s chain, moving entry [from] to [to].
  void moveEffect(int input, int from, int to) {
    final effects = state.forInput(input).effects;
    if (from < 0 || from >= effects.length) return;
    var target = to;
    if (target < 0) target = 0;
    if (target > effects.length - 1) target = effects.length - 1;
    if (from == target) return;
    final next = [...effects];
    next.insert(target, next.removeAt(from));
    _pushEffects(input, next);
  }

  /// Sets the type of monitor [input]'s chain entry [index] (resets its DSP
  /// state and seeds default params).
  void setEffectType(int input, int index, TrackEffectType type) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    final next = [...effects]..[index] = BuiltInEffect(type: type);
    _pushEffects(input, next);
  }

  /// Sets parameter [param] of monitor [input]'s chain entry [index] to [value]
  /// without resetting DSP state.
  void setEffectParam(int input, int index, int param, double value) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    final fx = monitor.effects[index];
    // Built-in params only — a plugin's parameter surface arrives in part 5.
    if (fx is! BuiltInEffect) return;
    if (param < 0 || param >= fx.params.length) return;
    final params = List<double>.of(fx.params)..[param] = value;
    final next = [...monitor.effects]..[index] = fx.copyWith(params: params);
    emit(state.withInput(monitor.copyWith(effects: next)));
    _repository.setMonitorEffectParam(
      input: input,
      index: index,
      param: param,
      value: value,
    );
    unawaited(_settings.saveMonitorEffects(input, _encodedChain(input, next)));
  }

  /// Sets hosted-plugin parameter [paramId] of monitor [input]'s chain entry
  /// [index] to the plain [value], routing it to the plugin through the RT
  /// param queue. Mirrors [setEffectParam] for [PluginEffect] entries, keyed by
  /// the stable plugin param id rather than a positional built-in index.
  void setPluginParam(int input, int index, int paramId, double value) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    final fx = monitor.effects[index];
    if (fx is! PluginEffect) return;
    final values = Map<int, double>.of(fx.paramValues)..[paramId] = value;
    final next = [...monitor.effects]
      ..[index] = fx.copyWith(paramValues: values);
    emit(state.withInput(monitor.copyWith(effects: next)));
    _repository.setMonitorPluginParam(
      input: input,
      index: index,
      paramId: paramId,
      value: value,
    );
    unawaited(_settings.saveMonitorEffects(input, _encodedChain(input, next)));
  }

  /// Enables/disables monitor [input]'s chain entry [index] without losing its
  /// type or parameters (R16; click-free ramp engine-side) — the input-stage
  /// half of the universal per-slot power control.
  void setEffectEnabled(int input, int index, {required bool enabled}) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    // Write first, then emit what actually landed — the repository owns the
    // flag flip across the sealed entry hierarchy, so re-reading it is more
    // honest than reproducing that dispatch here. [setChainEnabled] keeps the
    // same order for the same reason.
    _repository.setMonitorEffectEnabled(
      input: input,
      index: index,
      enabled: enabled,
    );
    // Fall back to the optimistic chain when the repository reports nothing:
    // it rejects the write (leaving its cache untouched) whenever it holds no
    // chain for this input — engine not running yet, a session load that just
    // cleared the key, or a unit-test fake. Emitting the empty read-back would
    // wipe the user's chain from the UI *and* persist the wipe. Matches the
    // guard [_pushEffects] and the restore path already carry.
    final applied = _repository.monitorEffects(input);
    final next = applied.isNotEmpty ? applied : monitor.effects;
    emit(state.withInput(monitor.copyWith(effects: next)));
    unawaited(_settings.saveMonitorEffects(input, _encodedChain(input, next)));
  }

  /// Enables/disables monitor [input]'s WHOLE chain in one atomic flip, leaving
  /// the per-entry flags intact (R15). A chain-disabled monitor sounds dry and
  /// stops being snapshot-copied onto recording lanes (D-CHAINDIS, R18).
  void setChainEnabled(int input, {required bool enabled}) {
    // Only flip a monitor the user actually has. `forInput` synthesizes a
    // default for an unknown input, so without this an input that exists on
    // the device but was never configured would be materialized into state and
    // persisted here — and the restore path counts a disabled chain as saved
    // state, so the phantom would come back on every subsequent boot.
    if (!state.hasInput(input)) return;
    final monitor = state.forInput(input);
    // Write, then emit — the same order as [setEffectEnabled].
    _repository.setMonitorChainEnabled(input: input, enabled: enabled);
    emit(state.withInput(monitor.copyWith(chainEnabled: enabled)));
    unawaited(
      _settings.saveMonitorEffects(
        input,
        _encodedChain(input, monitor.effects),
      ),
    );
  }

  /// Opens the native editor window for monitor [input]'s plugin chain entry
  /// [index] (D-WIN) and starts the ≤10 Hz inbound sync poll (D-SYNC): each
  /// tick mirrors editor-driven param moves onto the in-app knobs.
  void openPluginEditor(int input, int index) {
    _repository.openMonitorPluginEditor(input: input, index: index);
    final key = (input, index);
    _editorTimers.remove(key)?.cancel();
    _editorTimers[key] = Timer.periodic(_editorPollInterval, (timer) {
      if (_repository.refreshMonitorPluginParams(input: input, index: index)) {
        _emitInputEffects(input);
      }
      // Self-terminate when the user closes the native window directly.
      if (!_repository.isMonitorPluginEditorOpen(input: input, index: index)) {
        timer.cancel();
        _editorTimers.remove(key);
      }
    });
  }

  /// Closes monitor [input] chain entry [index]'s editor, stops its poll, and
  /// reflects the plugin's final params (D-SYNC read-back) into state.
  void closePluginEditor(int input, int index) {
    _editorTimers.remove((input, index))?.cancel(); // no leaked timer
    _repository.closeMonitorPluginEditor(input: input, index: index);
    _emitInputEffects(input);
  }

  /// Re-reads [input]'s remembered chain from the repository (where the inbound
  /// sync wrote the live values) and emits it, so the knobs follow the editor.
  void _emitInputEffects(int input) {
    final next = state
        .forInput(input)
        .copyWith(
          effects: _repository.monitorEffects(input),
        );
    emit(state.withInput(next));
  }

  void _pushEffects(int input, List<TrackEffect> effects) {
    // A structural edit reseats the input's slots, so cancel any editor-sync
    // poll keyed by a now-stale chain index (a reorder would otherwise rebind
    // the poll to a different plugin).
    _cancelEditorTimers(input);
    emit(state.withInput(state.forInput(input).copyWith(effects: effects)));
    _repository.setMonitorEffects(input: input, effects: effects);
    // The repository enriches plugin entries with their enumerated params
    // while applying the chain (so the in-app knobs render). Re-read to pick
    // those up; fall back to the optimistic chain when the repo reports nothing
    // (engine not running yet, or a unit-test fake).
    final applied = _repository.monitorEffects(input);
    if (applied.isNotEmpty) {
      emit(state.withInput(state.forInput(input).copyWith(effects: applied)));
    }
    // Persist the enriched chain (it carries each plugin's resolved display
    // name, so it survives a restart); fall back to the optimistic input only
    // when the repo reported nothing (engine not running / a unit-test fake).
    unawaited(
      _settings.saveMonitorEffects(
        input,
        _encodedChain(input, applied.isNotEmpty ? applied : effects),
      ),
    );
  }

  /// Encodes monitor [input]'s chain as the persisted envelope string (R15):
  /// the chain-enabled flag rides beside the entries in the one monitor-fx
  /// key. [effects] is passed rather than read from state because most save
  /// sites persist a just-computed chain the state emit races.
  String _encodedChain(int input, List<TrackEffect> effects) => encodeFxChain(
    FxChainEnvelope(
      chainEnabled: state.forInput(input).chainEnabled,
      entries: effects,
    ),
  );

  /// Cancels every editor-sync poll timer for monitor [input].
  void _cancelEditorTimers(int input) {
    _editorTimers.removeWhere((key, timer) {
      if (key.$1 == input) {
        timer.cancel();
        return true;
      }
      return false;
    });
  }

  /// Pushes the whole [monitor] to the repository: mode, then the chain's
  /// routing / mix / effects.
  void _applyMonitor(InputMonitor monitor) {
    final input = monitor.input;
    _repository
      ..setMonitorInputMode(input: input, mode: monitor.mode)
      ..setMonitorOutput(input: input, mask: monitor.outputMask)
      ..setMonitorVolume(input: input, volume: monitor.volume)
      ..setMonitorMute(input: input, muted: monitor.muted)
      ..setMonitorEffects(input: input, effects: monitor.effects)
      ..setMonitorChainEnabled(input: input, enabled: monitor.chainEnabled);
  }

  @override
  Future<void> close() {
    for (final timer in _editorTimers.values) {
      timer.cancel();
    }
    _editorTimers.clear();
    return super.close();
  }
}
