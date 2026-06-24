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
  }

  /// Reads hardware [input]'s persisted single-chain monitor, or null if none
  /// was saved.
  Future<InputMonitor?> _restoreInput(int input) async {
    final enabled = await _settings.loadMonitorInputEnabled(input);
    final outputMask = await _settings.loadMonitorOutput(input);
    final volume = await _settings.loadMonitorVolume(input);
    final muted = await _settings.loadMonitorMute(input);
    final effects = decodeTrackEffects(
      await _settings.loadMonitorEffects(input),
    );
    final anySaved =
        enabled != null ||
        outputMask != null ||
        volume != null ||
        muted != null ||
        effects.isNotEmpty;
    if (!anySaved) return null;
    return InputMonitor(
      input: input,
      enabled: enabled ?? false,
      outputMask: outputMask ?? 0x3,
      volume: volume ?? 1.0,
      muted: muted ?? false,
      effects: effects,
    );
  }

  /// Enables or disables monitoring of hardware [input], applying and
  /// persisting the change.
  Future<void> setEnabled(int input, {required bool enabled}) async {
    final monitor = state.forInput(input).copyWith(enabled: enabled);
    emit(state.withInput(monitor));
    _repository.setMonitorInputEnabled(input: input, enabled: enabled);
    await _settings.saveMonitorInputEnabled(input, enabled: enabled);
  }

  /// Sets and persists monitor [input]'s output bitmask.
  Future<void> setOutputMask(int input, int mask) async {
    final next = state.forInput(input).copyWith(outputMask: mask);
    emit(state.withInput(next));
    _repository.setMonitorOutput(input: input, mask: mask);
    await _settings.saveMonitorOutput(input, mask);
  }

  /// Sets and persists monitor [input]'s output gain (`0..1`).
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
  void addEffect(int input) {
    final effects = state.forInput(input).effects;
    _pushEffects(input, [
      ...effects,
      BuiltInEffect(type: TrackEffectType.drive),
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
      _settings.saveMonitorEffects(input, encodeTrackEffects(applied)),
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
    unawaited(_settings.saveMonitorEffects(input, encodeTrackEffects(next)));
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
    unawaited(_settings.saveMonitorEffects(input, encodeTrackEffects(next)));
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
        encodeTrackEffects(applied.isNotEmpty ? applied : effects),
      ),
    );
  }

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

  /// Pushes the whole [monitor] to the repository: enable, then the chain's
  /// routing / mix / effects.
  void _applyMonitor(InputMonitor monitor) {
    final input = monitor.input;
    _repository
      ..setMonitorInputEnabled(input: input, enabled: monitor.enabled)
      ..setMonitorOutput(input: input, mask: monitor.outputMask)
      ..setMonitorVolume(input: input, volume: monitor.volume)
      ..setMonitorMute(input: input, muted: monitor.muted)
      ..setMonitorEffects(input: input, effects: monitor.effects);
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
