import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Per-hardware-input live-monitor configuration.
///
/// Each monitored input fans its live signal out across independent monitor
/// lanes — each with its own effect chain, output routing, volume, and mute,
/// mirroring the multi-lane track model (minus recording). A lane with an empty
/// effect chain is the clean (dry) path.
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

  /// Restores the persisted per-input monitors and applies them to the
  /// repository. Reads only the per-(input, lane) keys; the one-time
  /// single-route → lanes migration runs at bootstrap, before this.
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

  /// Reads hardware [input]'s persisted monitor, or null if none was saved.
  Future<InputMonitor?> _restoreInput(int input) async {
    final enabled = await _settings.loadMonitorInputEnabled(input);
    final count = await _settings.loadMonitorLaneCount(input);
    final laneCount = (count == null || count < 1) ? 1 : count;
    var anySaved = enabled != null || count != null;
    final lanes = <MonitorLane>[];
    for (var lane = 0; lane < laneCount; lane++) {
      final outputMask = await _settings.loadMonitorLaneOutput(input, lane);
      final volume = await _settings.loadMonitorLaneVolume(input, lane);
      final muted = await _settings.loadMonitorLaneMute(input, lane);
      final effects = decodeTrackEffects(
        await _settings.loadMonitorLaneEffects(input, lane),
      );
      if (outputMask != null ||
          volume != null ||
          muted != null ||
          effects.isNotEmpty) {
        anySaved = true;
      }
      lanes.add(
        MonitorLane(
          outputMask: outputMask ?? 0x3,
          volume: volume ?? 1.0,
          muted: muted ?? false,
          effects: effects,
        ),
      );
    }
    if (!anySaved) return null;
    return InputMonitor(input: input, enabled: enabled ?? false, lanes: lanes);
  }

  /// Enables or disables monitoring of hardware [input], applying and
  /// persisting the change.
  Future<void> setEnabled(int input, {required bool enabled}) async {
    final monitor = state.forInput(input).copyWith(enabled: enabled);
    emit(state.withInput(monitor));
    _repository.setMonitorInputEnabled(input: input, enabled: enabled);
    await _settings.saveMonitorInputEnabled(input, enabled: enabled);
  }

  /// Appends a default (clean) lane to hardware [input]'s monitor, up to
  /// [kMaxLanes]. No-op once the cap is reached.
  Future<void> addLane(int input) async {
    final monitor = state.forInput(input);
    if (monitor.laneCount >= kMaxLanes) return;
    final lane = monitor.laneCount;
    final next = monitor.copyWith(
      lanes: [...monitor.lanes, const MonitorLane()],
    );
    emit(state.withInput(next));
    _repository.setMonitorLaneCount(input: input, count: next.laneCount);
    await _settings.saveMonitorLaneCount(input, next.laneCount);
    // Persist the appended lane's defaults so a later restore (or a stale key
    // from a prior larger count) never resurfaces wrong values.
    await _persistLane(input, lane, next.lanes[lane]);
  }

  /// Removes hardware [input]'s monitor [lane], collapsing the remaining lanes.
  /// No-op for the last lane or an out-of-range index.
  Future<void> removeLane(int input, int lane) async {
    final monitor = state.forInput(input);
    if (monitor.laneCount <= 1 || lane < 0 || lane >= monitor.laneCount) return;
    final lanes = [...monitor.lanes]..removeAt(lane);
    final next = monitor.copyWith(lanes: lanes);
    emit(state.withInput(next));
    // Lane indices shift, so re-apply and re-persist the whole monitor.
    _applyMonitor(next);
    await _persistMonitor(next);
  }

  /// Sets and persists monitor [input]'s lane [lane] output bitmask.
  Future<void> setLaneOutputMask(int input, int lane, int mask) async {
    final monitor = state.forInput(input);
    final next = monitor.withLane(
      lane,
      monitor.lane(lane).copyWith(outputMask: mask),
    );
    emit(state.withInput(next));
    _repository.setMonitorLaneOutput(input: input, lane: lane, mask: mask);
    await _settings.saveMonitorLaneOutput(input, lane, mask);
  }

  /// Sets and persists monitor [input]'s lane [lane] output gain (`0..1`).
  Future<void> setLaneVolume(int input, int lane, double volume) async {
    final monitor = state.forInput(input);
    final next = monitor.withLane(
      lane,
      monitor.lane(lane).copyWith(volume: volume),
    );
    emit(state.withInput(next));
    _repository.setMonitorLaneVolume(input: input, lane: lane, volume: volume);
    await _settings.saveMonitorLaneVolume(input, lane, volume);
  }

  /// Mutes or unmutes monitor [input]'s lane [lane].
  Future<void> setLaneMute(int input, int lane, {required bool muted}) async {
    final monitor = state.forInput(input);
    final next = monitor.withLane(
      lane,
      monitor.lane(lane).copyWith(muted: muted),
    );
    emit(state.withInput(next));
    _repository.setMonitorLaneMute(input: input, lane: lane, muted: muted);
    await _settings.saveMonitorLaneMute(input, lane, muted: muted);
  }

  /// Appends a default effect (drive) to monitor [input]'s lane [lane] chain.
  void addEffect(int input, int lane) {
    final effects = state.forInput(input).lane(lane).effects;
    _pushLaneEffects(input, lane, [
      ...effects,
      TrackEffect(type: TrackEffectType.drive),
    ]);
  }

  /// Removes monitor [input]'s lane [lane] chain entry at [index].
  void removeEffect(int input, int lane, int index) {
    final effects = state.forInput(input).lane(lane).effects;
    if (index < 0 || index >= effects.length) return;
    _pushLaneEffects(input, lane, [...effects]..removeAt(index));
  }

  /// Reorders monitor [input]'s lane [lane] chain, moving entry [from] to [to].
  void moveEffect(int input, int lane, int from, int to) {
    final effects = state.forInput(input).lane(lane).effects;
    if (from < 0 || from >= effects.length) return;
    var target = to;
    if (target < 0) target = 0;
    if (target > effects.length - 1) target = effects.length - 1;
    if (from == target) return;
    final next = [...effects];
    next.insert(target, next.removeAt(from));
    _pushLaneEffects(input, lane, next);
  }

  /// Sets the type of monitor [input]'s lane [lane] chain entry [index] (resets
  /// its DSP state and seeds default params).
  void setEffectType(int input, int lane, int index, TrackEffectType type) {
    final effects = state.forInput(input).lane(lane).effects;
    if (index < 0 || index >= effects.length) return;
    final next = [...effects]..[index] = TrackEffect(type: type);
    _pushLaneEffects(input, lane, next);
  }

  /// Sets parameter [param] of monitor [input]'s lane [lane] chain entry
  /// [index] to [value] without resetting DSP state.
  void setEffectParam(int input, int lane, int index, int param, double value) {
    final monitor = state.forInput(input);
    final laneState = monitor.lane(lane);
    if (index < 0 || index >= laneState.effects.length) return;
    final fx = laneState.effects[index];
    if (param < 0 || param >= fx.params.length) return;
    final params = List<double>.of(fx.params)..[param] = value;
    final next = [...laneState.effects]..[index] = fx.copyWith(params: params);
    emit(
      state.withInput(
        monitor.withLane(lane, laneState.copyWith(effects: next)),
      ),
    );
    _repository.setMonitorLaneEffectParam(
      input: input,
      lane: lane,
      index: index,
      param: param,
      value: value,
    );
    unawaited(
      _settings.saveMonitorLaneEffects(input, lane, encodeTrackEffects(next)),
    );
  }

  void _pushLaneEffects(int input, int lane, List<TrackEffect> effects) {
    final monitor = state.forInput(input);
    final next = monitor.withLane(
      lane,
      monitor.lane(lane).copyWith(effects: effects),
    );
    emit(state.withInput(next));
    _repository.setMonitorLaneEffects(
      input: input,
      lane: lane,
      effects: effects,
    );
    unawaited(
      _settings.saveMonitorLaneEffects(
        input,
        lane,
        encodeTrackEffects(effects),
      ),
    );
  }

  /// Pushes the whole [monitor] to the repository: enable + lane count, then
  /// each lane's routing / mix / effects.
  void _applyMonitor(InputMonitor monitor) {
    final input = monitor.input;
    _repository
      ..setMonitorInputEnabled(input: input, enabled: monitor.enabled)
      ..setMonitorLaneCount(input: input, count: monitor.laneCount);
    for (var lane = 0; lane < monitor.laneCount; lane++) {
      final l = monitor.lanes[lane];
      _repository
        ..setMonitorLaneOutput(input: input, lane: lane, mask: l.outputMask)
        ..setMonitorLaneVolume(input: input, lane: lane, volume: l.volume)
        ..setMonitorLaneMute(input: input, lane: lane, muted: l.muted)
        ..setMonitorLaneEffects(input: input, lane: lane, effects: l.effects);
    }
  }

  Future<void> _persistMonitor(InputMonitor monitor) async {
    await _settings.saveMonitorInputEnabled(
      monitor.input,
      enabled: monitor.enabled,
    );
    await _settings.saveMonitorLaneCount(monitor.input, monitor.laneCount);
    for (var lane = 0; lane < monitor.laneCount; lane++) {
      await _persistLane(monitor.input, lane, monitor.lanes[lane]);
    }
  }

  Future<void> _persistLane(int input, int lane, MonitorLane l) => Future.wait([
    _settings.saveMonitorLaneOutput(input, lane, l.outputMask),
    _settings.saveMonitorLaneVolume(input, lane, l.volume),
    _settings.saveMonitorLaneMute(input, lane, muted: l.muted),
    _settings.saveMonitorLaneEffects(
      input,
      lane,
      encodeTrackEffects(l.effects),
    ),
  ]);
}
