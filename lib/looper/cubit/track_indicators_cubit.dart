import 'package:bloc/bloc.dart';
import 'package:settings_repository/settings_repository.dart';

/// Whether per-track status indicators show on the Big Picture tiles.
///
/// A persisted, default-on view preference. The indicator state itself is a
/// pure function of track data (see `TrackIndicator.of`); this cubit only gates
/// whether the strip is shown at all.
class TrackIndicatorsCubit extends Cubit<bool> {
  /// Creates a [TrackIndicatorsCubit].
  ///
  /// Seeded `super(true)` so a default-on feature does not flash absent →
  /// present on launch before [load] restores the saved value.
  /// (`HighContrastCubit` seeds `false` because its default is off, so the
  /// asymmetry is intentional.)
  TrackIndicatorsCubit({required SettingsRepository settings})
    : _settings = settings,
      super(true);

  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted preference.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final on = await _settings.loadShowTrackIndicators();
    if (!isClosed) emit(on);
  }

  /// Sets and persists whether per-track status indicators are shown.
  Future<void> setEnabled({required bool value}) async {
    if (value != state) emit(value);
    await _settings.saveShowTrackIndicators(value: value);
  }

  /// Toggles the preference.
  Future<void> toggle() => setEnabled(value: !state);
}
