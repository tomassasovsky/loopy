import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// The UI snapshot-poll rate in Hz. Applied to the [LooperRepository] poll
/// cadence (how often the engine snapshot is read and the UI updated) and
/// persisted via [SettingsRepository]. Defaults to 60 Hz.
///
/// Higher is smoother but costs more CPU; lower eases load on slower machines.
class RefreshRateCubit extends Cubit<int> {
  /// Creates a [RefreshRateCubit] driving [repository]'s poll cadence, with the
  /// rate persisted through [settings]. Starts at 60 Hz until [load] restores
  /// the saved value.
  RefreshRateCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(60);

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Selectable refresh rates, in Hz.
  static const options = [30, 60, 120];

  /// Restores the persisted rate and applies it to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final hz = await _settings.loadRefreshHz();
    _repository.setPollInterval(_intervalFor(hz));
    if (!isClosed) emit(hz);
  }

  /// Sets and persists the refresh [hz], applying it to the repository now.
  Future<void> setHz(int hz) async {
    if (hz != state) {
      emit(hz);
      _repository.setPollInterval(_intervalFor(hz));
    }
    await _settings.saveRefreshHz(hz);
  }

  /// The poll interval for a rate in [hz] (a non-positive rate falls back to
  /// the engine's ~60 Hz default cadence).
  static Duration _intervalFor(int hz) =>
      Duration(microseconds: hz <= 0 ? 16000 : (1000000 / hz).round());
}
