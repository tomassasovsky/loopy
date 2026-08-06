import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';

part 'inputs_state.dart';

/// The persisted names given to the hardware inputs.
///
/// The rig's own words for its sockets: the interface says input 2, the
/// player says "mic" (`AUDIO / settings-inputs`). Deliberately the same shape
/// as `TracksCubit` — a small cubit that owns one persisted map and nothing
/// else — because it is the same problem one level down the signal path, and
/// two surfaces disagreeing about what an input is called would be exactly
/// the bug track names already had (#526).
///
/// The COUNT of inputs is the engine's, not this cubit's: a name is kept for
/// a socket whether or not the current device has it, so swapping interfaces
/// and swapping back does not lose the names.
class InputsCubit extends Cubit<InputsState> {
  /// Creates an [InputsCubit] covering [inputCount] hardware inputs.
  InputsCubit({
    required SettingsRepository settings,
    int inputCount = InputsState.maxInputs,
  }) : _settings = settings,
       super(InputsState(names: List.filled(inputCount, '')));

  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  int _loadGeneration = 0;

  /// Restores the persisted input names.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final generation = ++_loadGeneration;
    final names = [...state.names];
    for (var i = 0; i < names.length; i++) {
      final saved = await _settings.loadInputName(i);
      if (saved != null && saved.isNotEmpty) names[i] = saved;
    }
    if (!isClosed && generation == _loadGeneration) {
      emit(state.copyWith(names: names));
    }
  }

  /// Names hardware input [input] and persists it.
  Future<void> rename(int input, String name) async {
    final trimmed = name.trim();
    if (input < 0 || input >= state.names.length) return;
    _loadGeneration++;
    final names = [...state.names]..[input] = trimmed;
    emit(state.copyWith(names: names));
    await _settings.saveInputName(input, trimmed);
  }
}
