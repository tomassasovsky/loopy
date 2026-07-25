part of 'settings_tray_cubit.dart';

/// State for [SettingsTrayCubit]: pure ephemeral UI state for the console's
/// slide-down quick-access tray. Nothing here persists across a restart.
class SettingsTrayState extends Equatable {
  /// Creates a [SettingsTrayState].
  const SettingsTrayState({
    this.dragProgress = 0,
    this.isNavigating = false,
    this.brightness = 0.8,
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

  /// UI-only brightness slider value. Not persisted; not wired to any real
  /// display dimming yet.
  final double brightness;

  /// Returns a copy with the given fields replaced.
  SettingsTrayState copyWith({
    double? dragProgress,
    bool? isNavigating,
    double? brightness,
  }) => SettingsTrayState(
    dragProgress: dragProgress ?? this.dragProgress,
    isNavigating: isNavigating ?? this.isNavigating,
    brightness: brightness ?? this.brightness,
  );

  @override
  List<Object?> get props => [dragProgress, isNavigating, brightness];
}
