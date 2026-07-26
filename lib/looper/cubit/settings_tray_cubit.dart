import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

part 'settings_tray_state.dart';

/// Drives the console's slide-down quick-access tray (Settings / Signal
/// graph / WiFi / Bluetooth / Tuner / brightness) — the touch-reachable
/// counterpart to the `S`/`G` keyboard shortcuts on console/kiosk builds,
/// where the on-screen toolbar is hidden entirely.
///
/// Pure ephemeral UI state, unlike `TracksCubit`/`HighContrastCubit`: no
/// `SettingsRepository` dependency, and nothing here survives a restart.
class SettingsTrayCubit extends Cubit<SettingsTrayState> {
  /// Creates a [SettingsTrayCubit], closed with the default brightness.
  SettingsTrayCubit() : super(const SettingsTrayState());

  /// Live drag progress, clamped to `0..1`. Called every
  /// `onVerticalDragUpdate` frame while the handle is being dragged.
  void dragTo(double progress) {
    emit(state.copyWith(dragProgress: progress.clamp(0.0, 1.0)));
  }

  /// Settles a released drag: past the 50% distance threshold snaps open,
  /// otherwise closed. Distance-only this round — no velocity/fling
  /// threshold.
  void settleFromDrag() {
    if (state.dragProgress > 0.5) {
      open();
    } else {
      closeTray();
    }
  }

  /// Opens the tray (tap-on-handle, or programmatic).
  void open() => emit(state.copyWith(dragProgress: 1));

  /// Closes the tray (tap-on-handle, tap-on-scrim, or programmatic). Named
  /// `closeTray` rather than `close` — the latter is `Cubit.close()`, which
  /// disposes the bloc's stream; overriding it here would be a hard
  /// invalid-override error, not a UI action.
  void closeTray() => emit(state.copyWith(dragProgress: 0));

  /// Toggles open/closed. Only ever called from a tap (never mid-drag), so
  /// `dragProgress` is always settled at exactly `0` or `1` here.
  void toggle() {
    if (state.dragProgress > 0) {
      closeTray();
    } else {
      open();
    }
  }

  /// Marks a tray nav-button push as in flight — the tray disables both nav
  /// buttons until [endNavigating].
  void beginNavigating() => emit(state.copyWith(isNavigating: true));

  /// Clears the in-flight navigation guard set by [beginNavigating].
  void endNavigating() => emit(state.copyWith(isNavigating: false));

  /// Sets the local-only brightness slider value (`0..1`). Not persisted;
  /// not wired to any real display dimming.
  void setBrightness(double value) =>
      emit(state.copyWith(brightness: value.clamp(0.0, 1.0)));
}
