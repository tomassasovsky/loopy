import 'package:bloc/bloc.dart';
import 'package:settings_repository/settings_repository.dart';

/// Whether the secondary output-waveform window should open in tracks
/// mode. Persisted via [SettingsRepository]; defaults to enabled.
class WaveformWindowCubit extends Cubit<bool> {
  /// Creates a [WaveformWindowCubit], enabled until [load] restores the saved
  /// preference.
  WaveformWindowCubit({required SettingsRepository settings})
    : _settings = settings,
      super(true);

  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted preference.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    emit(await _settings.loadShowWaveformWindow());
  }

  /// Sets and persists whether the waveform window is enabled.
  Future<void> setEnabled({required bool value}) async {
    if (value != state) emit(value);
    await _settings.saveShowWaveformWindow(value: value);
  }

  /// Toggles the preference.
  Future<void> toggle() => setEnabled(value: !state);
}
