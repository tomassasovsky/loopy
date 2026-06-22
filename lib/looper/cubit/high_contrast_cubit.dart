import 'package:bloc/bloc.dart';
import 'package:settings_repository/settings_repository.dart';

/// Whether the app forces its high-contrast theme.
///
/// macOS / Windows / Linux do not deliver the OS "increase contrast" flag to
/// Flutter (`MediaQuery.highContrast` is iOS-only), so this manual, persisted
/// toggle is the only way to reach the high-contrast palette on desktop. On
/// iOS the OS flag still applies too, via `MaterialApp.highContrastTheme`.
/// Defaults to off until [load] restores the saved preference.
class HighContrastCubit extends Cubit<bool> {
  /// Creates a [HighContrastCubit], off until [load] restores the saved value.
  HighContrastCubit({required SettingsRepository settings})
    : _settings = settings,
      super(false);

  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted preference.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final on = await _settings.loadHighContrast();
    if (!isClosed) emit(on);
  }

  /// Sets and persists whether the high-contrast theme is forced.
  Future<void> setEnabled({required bool value}) async {
    if (value != state) emit(value);
    await _settings.saveHighContrast(value: value);
  }

  /// Toggles the preference.
  Future<void> toggle() => setEnabled(value: !state);
}
