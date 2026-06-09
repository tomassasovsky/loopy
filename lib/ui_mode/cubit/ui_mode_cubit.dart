import 'package:bloc/bloc.dart';
import 'package:settings_repository/settings_repository.dart';

/// The app's top-level presentation mode.
enum UiMode {
  /// The working desktop layout (single window).
  desktop,

  /// The full-screen performance view, with a separate output-waveform window.
  bigPicture,
}

/// Holds the current [UiMode] and persists it via [SettingsRepository].
class UiModeCubit extends Cubit<UiMode> {
  /// Creates a [UiModeCubit], defaulting to [UiMode.bigPicture] until [load]
  /// restores a persisted choice. Big Picture is the default look and feel.
  UiModeCubit({required SettingsRepository settings})
    : _settings = settings,
      super(UiMode.bigPicture);

  final SettingsRepository _settings;

  /// Restores the persisted mode, if any.
  Future<void> load() async {
    final name = await _settings.loadUiMode();
    for (final mode in UiMode.values) {
      if (mode.name == name) {
        emit(mode);
        return;
      }
    }
  }

  /// Sets and persists the mode.
  Future<void> setMode(UiMode mode) async {
    if (mode != state) emit(mode);
    await _settings.saveUiMode(mode.name);
  }

  /// Toggles between desktop and big-picture.
  Future<void> toggle() => setMode(
    state == UiMode.desktop ? UiMode.bigPicture : UiMode.desktop,
  );
}
