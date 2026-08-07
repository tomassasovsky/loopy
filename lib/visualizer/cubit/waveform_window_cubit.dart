import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';

/// The secondary output-waveform window: whether it is *wanted*, and whether
/// the last attempt to open it actually worked.
///
/// Two facts, deliberately not one. [enabled] is a preference — persisted,
/// restored at launch, and true even on a rig whose second screen is
/// unplugged. [openFailed] is a property of the last attempt: not persisted,
/// cleared the moment the preference is set again, and reported by whoever
/// made the attempt.
///
/// It lives here rather than in the face that draws it because the attempt
/// that matters most happens at LAUNCH, with the tray shut — a flag held in
/// the Display tab's own `State` would be created after the failure it exists
/// to report, and would show a clean face on a console with no second screen.
class WaveformWindowState extends Equatable {
  /// Creates a [WaveformWindowState].
  const WaveformWindowState({this.enabled = true, this.openFailed = false});

  /// Whether the window should be open.
  final bool enabled;

  /// Whether the last attempt to open it failed.
  final bool openFailed;

  /// Returns a copy with the given fields replaced.
  WaveformWindowState copyWith({bool? enabled, bool? openFailed}) =>
      WaveformWindowState(
        enabled: enabled ?? this.enabled,
        openFailed: openFailed ?? this.openFailed,
      );

  @override
  List<Object?> get props => [enabled, openFailed];
}

/// Whether the secondary output-waveform window should open in tracks
/// mode. Persisted via [SettingsRepository]; defaults to enabled.
class WaveformWindowCubit extends Cubit<WaveformWindowState> {
  /// Creates a [WaveformWindowCubit], enabled until [load] restores the saved
  /// preference.
  WaveformWindowCubit({required SettingsRepository settings})
    : _settings = settings,
      super(const WaveformWindowState());

  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted preference.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final enabled = await _settings.loadShowWaveformWindow();
    if (!isClosed) emit(state.copyWith(enabled: enabled));
  }

  /// Sets and persists whether the waveform window is enabled.
  ///
  /// Clears [WaveformWindowState.openFailed]: turning the switch either way is
  /// a fresh instruction, and a failure left standing across it would be
  /// reporting an attempt the user has already superseded.
  Future<void> setEnabled({required bool value}) async {
    if (value != state.enabled || state.openFailed) {
      emit(WaveformWindowState(enabled: value));
    }
    await _settings.saveShowWaveformWindow(value: value);
  }

  /// Toggles the preference.
  Future<void> toggle() => setEnabled(value: !state.enabled);

  /// Records that an attempt to open the window did not succeed.
  ///
  /// Called by whoever made the attempt — the app shell, which owns the
  /// window — never by a face. Not persisted: the next launch tries again.
  void reportOpenFailed() {
    if (state.openFailed) return;
    emit(state.copyWith(openFailed: true));
  }

  /// Tries again after a failure.
  ///
  /// Clears the flag, which is itself the signal: the shell re-syncs on any
  /// change, and [WaveformWindowState.enabled] is still true, so dropping the
  /// failure IS the retry. No-op when nothing failed, so a stray call cannot
  /// churn the window.
  void retryOpen() {
    if (!state.openFailed) return;
    emit(state.copyWith(openFailed: false));
  }
}
