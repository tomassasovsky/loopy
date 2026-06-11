import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Per-hardware-input live-monitor configuration.
///
/// Each monitored input routes its live signal — through its own effect chain —
/// to chosen outputs, independent of any track. Replaces the old global
/// monitor-FX bus and "monitor follows a track" model.
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

  /// Hardware-input ceiling scanned on restore (matches the engine's
  /// `LE_MAX_INPUTS`). Only inputs with saved state populate the map.
  static const int _maxInputs = 8;

  /// Restores the persisted per-input monitors and applies them to the
  /// repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final loaded = await Future.wait([
      for (var input = 0; input < _maxInputs; input++) _restoreInput(input),
    ]);
    if (isClosed) return;
    final restored = <int, InputMonitor>{};
    for (final monitor in loaded) {
      if (monitor != null) restored[monitor.input] = monitor;
    }
    emit(MonitorState(inputs: restored));
    for (final monitor in restored.values) {
      _applyRouting(monitor);
      _repository.setMonitorEffects(
        input: monitor.input,
        effects: monitor.effects,
      );
    }
  }

  /// Reads hardware [input]'s persisted monitor, or null if none was saved.
  Future<InputMonitor?> _restoreInput(int input) async {
    final routing = await _settings.loadMonitorInput(input);
    final effects = decodeTrackEffects(
      await _settings.loadMonitorInputEffects(input),
    );
    if (routing == null && effects.isEmpty) return null;
    return InputMonitor(
      input: input,
      enabled: routing?.$1 ?? false,
      outputMask: routing?.$2 ?? 0x3,
      dryOutputMask: await _settings.loadMonitorInputDry(input),
      effects: effects,
    );
  }

  /// Enables or disables monitoring of hardware [input], applying and
  /// persisting the change.
  Future<void> setEnabled(int input, {required bool enabled}) async {
    final monitor = state.forInput(input).copyWith(enabled: enabled);
    emit(state.withInput(monitor));
    _applyRouting(monitor);
    await _persistRouting(monitor);
  }

  /// Sets and persists hardware [input]'s monitor (effected) output bitmask.
  Future<void> setOutputMask(int input, int mask) async {
    final monitor = state.forInput(input).copyWith(outputMask: mask);
    emit(state.withInput(monitor));
    _applyRouting(monitor);
    await _persistRouting(monitor);
  }

  /// Sets and persists hardware [input]'s monitor dry-send output bitmask — the
  /// CLEAN signal's outputs, in parallel with the effected route (`0` = off).
  Future<void> setDryOutputMask(int input, int mask) async {
    final monitor = state.forInput(input).copyWith(dryOutputMask: mask);
    emit(state.withInput(monitor));
    _applyRouting(monitor);
    await _persistRouting(monitor);
  }

  /// Appends a default effect (drive) to hardware [input]'s monitor chain.
  void addEffect(int input) {
    final effects = state.forInput(input).effects;
    _pushEffects(input, [
      ...effects,
      TrackEffect(type: TrackEffectType.drive),
    ]);
  }

  /// Removes hardware [input]'s monitor chain entry at [index].
  void removeEffect(int input, int index) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    _pushEffects(input, [...effects]..removeAt(index));
  }

  /// Reorders hardware [input]'s monitor chain, moving entry [from] to [to].
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

  /// Sets the type of hardware [input]'s monitor chain entry [index] (resets
  /// its DSP state and seeds default params).
  void setEffectType(int input, int index, TrackEffectType type) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    final next = [...effects]..[index] = TrackEffect(type: type);
    _pushEffects(input, next);
  }

  /// Sets parameter [param] of hardware [input]'s monitor chain entry [index]
  /// to [value] without resetting DSP state.
  void setEffectParam(int input, int index, int param, double value) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    final fx = monitor.effects[index];
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
    unawaited(
      _settings.saveMonitorInputEffects(input, encodeTrackEffects(next)),
    );
  }

  void _pushEffects(int input, List<TrackEffect> effects) {
    final monitor = state.forInput(input).copyWith(effects: effects);
    emit(state.withInput(monitor));
    _repository.setMonitorEffects(input: input, effects: effects);
    unawaited(
      _settings.saveMonitorInputEffects(input, encodeTrackEffects(effects)),
    );
  }

  void _applyRouting(InputMonitor monitor) {
    _repository
      ..setMonitorInput(
        input: monitor.input,
        enabled: monitor.enabled,
        outputMask: monitor.outputMask,
      )
      ..setMonitorDry(
        input: monitor.input,
        dryOutputMask: monitor.dryOutputMask,
      );
  }

  Future<void> _persistRouting(InputMonitor monitor) => Future.wait([
    _settings.saveMonitorInput(
      monitor.input,
      enabled: monitor.enabled,
      outputMask: monitor.outputMask,
    ),
    _settings.saveMonitorInputDry(monitor.input, monitor.dryOutputMask),
  ]);
}
