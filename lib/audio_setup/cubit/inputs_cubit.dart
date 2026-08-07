import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart' show kMaxInputs;
import 'package:settings_repository/settings_repository.dart';

part 'inputs_state.dart';

/// What the player calls each hardware input.
///
/// Modelled on `TracksCubit` because it is the same problem one level down the
/// signal path: the interface says input 2 and the player says "mic". The one
/// thing that is NOT a copy is the scope — names are kept **per socket up to
/// the engine's input ceiling**, not per current device, so swapping interfaces
/// and swapping back does not lose them.
///
/// One persisted map and nothing else. Provided at app level and loaded once,
/// because an input is called what the player calls it on every surface that
/// shows one — the Audio face's input list, the Tracks routing summary and the
/// per-track lane list all read the same names through `l10n.inputName`.
class InputsCubit extends Cubit<InputsState> {
  /// Creates an [InputsCubit].
  InputsCubit({required SettingsRepository settings})
    : _settings = settings,
      super(InputsState());

  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Sockets renamed while a load was in flight.
  ///
  /// The restore walks the sockets one await at a time, so a rename part-way
  /// through would be overwritten by the list the walk started with. Recording
  /// which sockets moved lets the restore land MERGED rather than be abandoned
  /// — dropping it wholesale would lose every OTHER socket's persisted name for
  /// the session, since [load] is memoised and never runs again.
  final Set<int> _renamedDuringLoad = {};

  /// Whether a load is currently walking the sockets.
  bool _loading = false;

  /// Restores the persisted names.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    _loading = true;
    _renamedDuringLoad.clear();
    final names = [...state.names];
    for (var input = 0; input < names.length; input++) {
      final saved = await _settings.loadInputName(input);
      if (saved != null && saved.isNotEmpty) names[input] = saved;
    }
    _loading = false;
    if (isClosed) return;
    // A socket renamed while this was walking keeps the name the user just
    // gave it; every other socket takes what was on disk.
    for (final input in _renamedDuringLoad) {
      if (input < names.length) names[input] = state.names[input];
    }
    _renamedDuringLoad.clear();
    emit(state.copyWith(names: names));
  }

  /// Names hardware [input], or hands the socket back its ordinal when [name]
  /// trims to nothing.
  ///
  /// An empty name is a real answer here, unlike a track's: `AUDIO /
  /// settings-rename` has no Clear button, only a backspace and Save, so
  /// emptying the field IS how an input is un-named.
  Future<void> rename(int input, String name) async {
    if (input < 0 || input >= state.names.length) return;
    final trimmed = name.trim();
    if (trimmed == state.names[input]) return;
    if (_loading) _renamedDuringLoad.add(input);
    final names = [...state.names]..[input] = trimmed;
    emit(state.copyWith(names: names));
    if (trimmed.isEmpty) {
      await _settings.clearInputName(input);
      return;
    }
    await _settings.saveInputName(input, trimmed);
  }
}
