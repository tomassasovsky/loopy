import 'package:bloc/bloc.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/network/network_tab.dart';
import 'package:settings_repository/settings_repository.dart';

part 'settings_tray_state.dart';

/// Drives the console's slide-down quick-access tray (Settings / Signal
/// graph / Network / Tuner / brightness) — the touch-reachable
/// counterpart to the `S`/`G` keyboard shortcuts on console/kiosk builds,
/// where the on-screen toolbar is hidden entirely.
///
/// Tray open/drag state is ephemeral. Brightness is persisted via
/// [SettingsRepository] (or [DisplayBrightnessCubit] when provided) and dimmed
/// in software app-wide; DDC/CI is applied when the host helper supports it.
class SettingsTrayCubit extends Cubit<SettingsTrayState> {
  /// Creates a [SettingsTrayCubit].
  SettingsTrayCubit({
    required SettingsRepository settings,
    BrightnessClient brightnessClient = const UnsupportedBrightnessClient(),
    DisplayBrightnessCubit? displayBrightness,
  }) : _settings = settings,
       _brightnessClient = brightnessClient,
       _displayBrightness = displayBrightness,
       super(const SettingsTrayState());

  final SettingsRepository _settings;
  final BrightnessClient _brightnessClient;
  final DisplayBrightnessCubit? _displayBrightness;
  Future<void>? _loadFuture;
  bool _brightnessSupported = false;

  /// Restores persisted brightness and probes whether the display helper
  /// can apply it.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final display = _displayBrightness;
    if (display != null) {
      await display.load();
      if (isClosed) return;
      emit(state.copyWith(brightness: display.state));
      return;
    }
    final saved = clampDisplayBrightness(await _settings.loadBrightness());
    _brightnessSupported = await _brightnessClient.isSupported();
    if (isClosed) return;
    emit(state.copyWith(brightness: saved));
    if (_brightnessSupported) {
      try {
        await _brightnessClient.set(saved);
      } on Object {
        // Slider still works locally if apply fails.
      }
    }
  }

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
  /// invalid-override error, not a UI action. Always returns to the home
  /// face so the next open isn't stuck in WiFi/Bluetooth.
  void closeTray() => emit(
    state.copyWith(
      dragProgress: 0,
      destination: SettingsTrayDestination.home,
    ),
  );

  /// Toggles open/closed. Only ever called from a tap (never mid-drag), so
  /// `dragProgress` is always settled at exactly `0` or `1` here.
  void toggle() {
    if (state.dragProgress > 0) {
      closeTray();
    } else {
      open();
    }
  }

  /// Expands the in-tray Network panel on its WiFi tab (tray stays open).
  void openWifi() => _openNetwork(NetworkTab.wifi);

  /// Expands the in-tray Network panel on its Bluetooth tab (tray stays open).
  void openBluetooth() => _openNetwork(NetworkTab.bluetooth);

  /// The radio shortcuts both land on the same face — they differ only in
  /// which tab of it they land on, which is exactly what merging the two
  /// rail entries into one Network domain (#498) means.
  void _openNetwork(NetworkTab tab) => emit(
    state.copyWith(
      dragProgress: 1,
      destination: SettingsTrayDestination.network,
      networkTab: tab,
    ),
  );

  /// Switches the Control face's tab. Like [showNetworkTab], the strip is
  /// only reachable while its domain is already showing.
  void showControlTab(ControlTab tab) => emit(state.copyWith(controlTab: tab));

  /// Switches the Network face's tab. Does not touch
  /// [SettingsTrayState.destination]:
  /// the tab strip is only reachable while Network is already showing.
  void showNetworkTab(NetworkTab tab) => emit(state.copyWith(networkTab: tab));

  /// Returns from an expanded panel to the tile grid.
  void showHome() =>
      emit(state.copyWith(destination: SettingsTrayDestination.home));

  /// Selects [destination] without changing whether the tray is open — the
  /// navigation rail's one entry point.
  ///
  /// Deliberately does NOT set `dragProgress`: the rail is only reachable
  /// while the tray is already open, and writing an open bit here would give
  /// the destination a second say in whether the tray is showing. Openness
  /// stays [SettingsTrayState.dragProgress]'s alone.
  void showDestination(SettingsTrayDestination destination) =>
      emit(state.copyWith(destination: destination));

  /// Marks a tray nav-button push as in flight — the tray disables both nav
  /// buttons until [endNavigating].
  void beginNavigating() => emit(state.copyWith(isNavigating: true));

  /// Clears the in-flight navigation guard set by [beginNavigating].
  void endNavigating() => emit(state.copyWith(isNavigating: false));

  /// Sets brightness (`kMinDisplayBrightness..1`), persists it, and applies
  /// (software + optional DDC via [DisplayBrightnessCubit], or the legacy
  /// client path).
  Future<void> setBrightness(double value) async {
    final clamped = clampDisplayBrightness(value);
    emit(state.copyWith(brightness: clamped));
    final display = _displayBrightness;
    if (display != null) {
      await display.setBrightness(clamped);
      return;
    }
    await _settings.saveBrightness(clamped);
    if (_brightnessSupported) {
      try {
        await _brightnessClient.set(clamped);
      } on Object {
        // Keep UI/persistence even if the panel rejects the set.
      }
    }
  }
}
