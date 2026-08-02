part of 'settings_tray_cubit.dart';

/// Which face the open tray is showing — home tiles, or an in-tray WiFi /
/// Bluetooth panel (Control-Center expand, not a full-screen route).
enum SettingsTrayDestination {
  /// Tile grid + brightness.
  home,

  /// In-tray WiFi panel.
  wifi,

  /// In-tray Bluetooth panel.
  bluetooth,
}

/// State for [SettingsTrayCubit]: tray open/drag is ephemeral; brightness is
/// persisted and applied to the display when the appliance helper supports it.
class SettingsTrayState extends Equatable {
  /// Creates a [SettingsTrayState].
  const SettingsTrayState({
    this.dragProgress = 0,
    this.isNavigating = false,
    this.brightness = 0.8,
    this.destination = SettingsTrayDestination.home,
  });

  /// Live drag/settle progress in `0..1` — `0` fully closed, `1` fully open.
  /// Driven every frame during a drag; jumps to its final value on settle
  /// (the view animates the visual transition to that value itself). The
  /// view drives all tray rendering from this one field — there is no
  /// separate "is it open" bit to keep in sync, since between drags this is
  /// always settled at exactly `0` or `1`.
  final double dragProgress;

  /// True from the instant a tray nav button is tapped until the pushed
  /// route pops — guards against a rapid double-tap double-pushing
  /// `showSignalPage` (which, unlike `openLoopySettings`, has no re-entrancy
  /// guard of its own).
  final bool isNavigating;

  /// Brightness slider value (`0..1`). Persisted via SettingsRepository;
  /// applied through BrightnessClient when DDC/CI is available.
  final double brightness;

  /// In-tray face: home tiles or a WiFi/Bluetooth expand panel.
  final SettingsTrayDestination destination;

  /// Returns a copy with the given fields replaced.
  SettingsTrayState copyWith({
    double? dragProgress,
    bool? isNavigating,
    double? brightness,
    SettingsTrayDestination? destination,
  }) => SettingsTrayState(
    dragProgress: dragProgress ?? this.dragProgress,
    isNavigating: isNavigating ?? this.isNavigating,
    brightness: brightness ?? this.brightness,
    destination: destination ?? this.destination,
  );

  @override
  List<Object?> get props => [
    dragProgress,
    isNavigating,
    brightness,
    destination,
  ];
}
