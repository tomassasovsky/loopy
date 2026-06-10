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

/// Monitor-routing configuration: the [mode] plus the custom input/output masks.
class MonitorState extends Equatable {
  /// Creates a [MonitorState].
  const MonitorState({
    this.mode = MonitorMode.custom,
    this.inputMask = 0x1,
    this.outputMask = 0x3,
  });

  /// What the monitor routes (custom masks vs. the selected track).
  final MonitorMode mode;

  /// Custom monitor input bitmask (which inputs are folded into the monitor).
  final int inputMask;

  /// Custom monitor output bitmask (which outputs the monitor plays to).
  final int outputMask;

  /// Returns a copy with the given overrides.
  MonitorState copyWith({MonitorMode? mode, int? inputMask, int? outputMask}) =>
      MonitorState(
        mode: mode ?? this.mode,
        inputMask: inputMask ?? this.inputMask,
        outputMask: outputMask ?? this.outputMask,
      );

  @override
  List<Object?> get props => [mode, inputMask, outputMask];
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
    if (isClosed) return;
    emit(
      MonitorState(mode: mode, inputMask: inputMask, outputMask: outputMask),
    );
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
