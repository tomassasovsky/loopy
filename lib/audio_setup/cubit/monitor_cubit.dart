import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// What the live monitor routes.
enum MonitorMode {
  /// Use the custom monitor input/output masks.
  custom,

  /// Mirror the currently-selected track's input/output routing.
  followSelected;

  /// The persisted token for this mode.
  String get token => name;

  /// Parses a persisted [token], defaulting to [custom].
  static MonitorMode fromToken(String? token) => MonitorMode.values.firstWhere(
    (m) => m.name == token,
    orElse: () => MonitorMode.custom,
  );
}

/// Monitor-routing configuration: the [mode], the custom input/output masks,
/// and the global monitor-FX bus [effects] (applied to the monitor in every
/// mode).
class MonitorState extends Equatable {
  /// Creates a [MonitorState].
  const MonitorState({
    this.mode = MonitorMode.custom,
    this.inputMask = 0x1,
    this.outputMask = 0x3,
    this.effects = const [],
  });

  /// What the monitor routes (custom masks vs. the selected track).
  final MonitorMode mode;

  /// Custom monitor input bitmask (which inputs are folded into the monitor).
  final int inputMask;

  /// Custom monitor output bitmask (which outputs the monitor plays to).
  final int outputMask;

  /// The monitor-FX bus chain (ordered). Applied to the monitored signal in
  /// every mode; entries have no pre/post (the `stage` field is unused).
  final List<TrackEffect> effects;

  /// Returns a copy with the given overrides.
  MonitorState copyWith({
    MonitorMode? mode,
    int? inputMask,
    int? outputMask,
    List<TrackEffect>? effects,
  }) => MonitorState(
    mode: mode ?? this.mode,
    inputMask: inputMask ?? this.inputMask,
    outputMask: outputMask ?? this.outputMask,
    effects: effects ?? this.effects,
  );

  @override
  List<Object?> get props => [mode, inputMask, outputMask, effects];
}

/// Owns the live monitor routing: applies it to the [LooperRepository] and
/// persists it via [SettingsRepository]. In [MonitorMode.followSelected] the
/// monitor mirrors the selected track; the app feeds the selection through
/// [setSelectedChannel].
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
  int _selectedChannel = 0;

  /// Restores the persisted routing and applies it to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final mode = MonitorMode.fromToken(await _settings.loadMonitorMode());
    final inputMask = await _settings.loadMonitorInputMask();
    final outputMask = await _settings.loadMonitorOutputMask();
    final effects = decodeTrackEffects(await _settings.loadMonitorEffects());
    if (isClosed) return;
    emit(
      MonitorState(
        mode: mode,
        inputMask: inputMask,
        outputMask: outputMask,
        effects: effects,
      ),
    );
    _repository.setMonitorEffects(effects: effects);
    _apply();
  }

  /// Records the currently-selected track; when following the selection, the
  /// monitor mirrors it now.
  void setSelectedChannel(int channel) {
    _selectedChannel = channel;
    if (state.mode == MonitorMode.followSelected) {
      _repository.setMonitorFollowTrack(channel);
    }
  }

  /// Sets and persists the monitor [mode], applying it now.
  Future<void> setMode(MonitorMode mode) async {
    if (mode != state.mode) {
      emit(state.copyWith(mode: mode));
      _apply();
    }
    await _settings.saveMonitorMode(mode.token);
  }

  /// Sets and persists the custom monitor input [mask], applying it if custom.
  Future<void> setInputMask(int mask) async {
    emit(state.copyWith(inputMask: mask));
    if (state.mode == MonitorMode.custom) {
      _repository.setMonitorInputMask(mask);
    }
    await _settings.saveMonitorInputMask(mask);
  }

  /// Sets and persists the custom monitor output [mask], applying it if custom.
  Future<void> setOutputMask(int mask) async {
    emit(state.copyWith(outputMask: mask));
    if (state.mode == MonitorMode.custom) {
      _repository.setMonitorOutputMask(mask);
    }
    await _settings.saveMonitorOutputMask(mask);
  }

  /// Appends a default effect (drive) to the monitor-FX bus.
  void addEffect() => _pushEffects([
    ...state.effects,
    TrackEffect(type: TrackEffectType.drive),
  ]);

  /// Removes the monitor-FX bus entry at [index].
  void removeEffect(int index) {
    if (index < 0 || index >= state.effects.length) return;
    _pushEffects([...state.effects]..removeAt(index));
  }

  /// Reorders the monitor-FX bus, moving the entry at [from] to [to].
  void moveEffect(int from, int to) {
    final effects = state.effects;
    if (from < 0 || from >= effects.length) return;
    var target = to;
    if (target < 0) target = 0;
    if (target > effects.length - 1) target = effects.length - 1;
    if (from == target) return;
    final next = [...effects];
    next.insert(target, next.removeAt(from));
    _pushEffects(next);
  }

  /// Sets the type of monitor-FX bus entry [index] (resets its DSP state).
  void setEffectType(int index, TrackEffectType type) {
    if (index < 0 || index >= state.effects.length) return;
    final next = [...state.effects]
      ..[index] = TrackEffect(type: type); // type change seeds default params
    _pushEffects(next);
  }

  /// Sets parameter [param] of monitor-FX bus entry [index] to [value] without
  /// resetting DSP state.
  void setEffectParam(int index, int param, double value) {
    if (index < 0 || index >= state.effects.length) return;
    final fx = state.effects[index];
    if (param < 0 || param >= fx.params.length) return;
    final params = List<double>.of(fx.params)..[param] = value;
    final next = [...state.effects]..[index] = fx.copyWith(params: params);
    emit(state.copyWith(effects: next));
    _repository.setMonitorEffectParam(index: index, param: param, value: value);
    unawaited(_settings.saveMonitorEffects(encodeTrackEffects(next)));
  }

  /// Emits, applies (structural — resets DSP), and persists [effects].
  void _pushEffects(List<TrackEffect> effects) {
    emit(state.copyWith(effects: effects));
    _repository.setMonitorEffects(effects: effects);
    unawaited(_settings.saveMonitorEffects(encodeTrackEffects(effects)));
  }

  void _apply() {
    if (state.mode == MonitorMode.followSelected) {
      _repository.setMonitorFollowTrack(_selectedChannel);
    } else {
      _repository
        ..setMonitorFollowTrack(null)
        ..setMonitorInputMask(state.inputMask)
        ..setMonitorOutputMask(state.outputMask);
    }
  }
}
