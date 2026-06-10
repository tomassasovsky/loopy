import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Whether recording is quantized to the loop grid: a record/overdub press
/// over an existing master loop is deferred to the next loop top so captures
/// align to the grid (a second press before the boundary cancels it). Applied
/// to the [LooperRepository] and persisted via [SettingsRepository]. Defaults
/// to off (the free-running behaviour).
class QuantizeCubit extends Cubit<bool> {
  /// Creates a [QuantizeCubit] driving [repository], with the choice persisted
  /// through [settings]. Starts off until [load] restores the saved value.
  QuantizeCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(false);

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted preference and applies it to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final on = await _settings.loadQuantize();
    _repository.setQuantize(enabled: on);
    if (!isClosed) emit(on);
  }

  /// Sets and persists whether recording is quantized, applying it now.
  Future<void> setEnabled({required bool value}) async {
    if (value != state) {
      emit(value);
      _repository.setQuantize(enabled: value);
    }
    await _settings.saveQuantize(value: value);
  }

  /// Toggles the preference.
  Future<void> toggle() => setEnabled(value: !state);
}
