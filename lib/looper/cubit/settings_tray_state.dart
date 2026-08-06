part of 'settings_tray_cubit.dart';

/// Which face the open tray is showing — home tiles, or one of the in-tray
/// config panels (Control-Center expand, not a full-screen route).
///
/// Every value here is a destination the tray's own navigation rail can
/// select. Surfaces that still push a full-screen route (Settings, and the
/// Signal page until the Routing panel lands) deliberately have no value:
/// a rail item that navigates away would lie about what the rail is.
///
/// Later parts of the console redesign (#442) each add their own value here
/// alongside the panel that fills it — the enum is not pre-populated with
/// placeholders, because a rail item that does nothing when tapped is worse
/// than a two-line enum edit.
enum SettingsTrayDestination {
  /// Tile grid + brightness.
  home,

  /// In-tray Control panel: the footswitches and external MIDI as two tabs of
  /// one domain (#516). Was a Pedal-only destination (#440) — the console's
  /// path to remapping footswitches, which otherwise sits three levels deep in
  /// Settings.
  control,

  /// In-tray Loop panel: tempo, click and mode as three tabs of one domain
  /// (#518).
  loop,

  /// In-tray Tracks panel: names, lengths and routing as three tabs of one
  /// domain (#523).
  tracks,

  /// In-tray Audio panel: device, recording and status as three tabs of one
  /// domain (#528).
  audio,

  /// In-tray System panel: display and updates as tabs of one domain (#530).
  system,

  /// In-tray tuner panel. Placement only — the tuner itself is not
  /// implemented, and this face says so.
  tuner,

  /// In-tray Network panel: WiFi and Bluetooth as two tabs of one domain.
  ///
  /// One entry, not two: a rail slot per radio was the same waste as one
  /// bucket for twelve settings groups (#498). Which radio is showing is
  /// [SettingsTrayState.networkTab], not a destination of its own.
  network,
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
    this.networkTab = NetworkTab.wifi,
    this.controlTab = ControlTab.pedal,
    this.loopTab = LoopTab.tempo,
    this.tracksTab = TracksTab.names,
    this.audioTab = AudioTab.device,
    this.systemTab = SystemTab.display,
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
  /// `showSignalPage` (which, unlike `openSegnoSettings`, has no re-entrancy
  /// guard of its own).
  final bool isNavigating;

  /// Brightness slider value (`0..1`). Persisted via SettingsRepository;
  /// applied through BrightnessClient when DDC/CI is available.
  final double brightness;

  /// In-tray face: home tiles, or one of the rail's config panels.
  final SettingsTrayDestination destination;

  /// Which tab the Control face shows. Kept across navigation for the same
  /// reason as [networkTab].
  final ControlTab controlTab;

  /// Which tab the Loop face shows. Kept across navigation, like the others.
  final LoopTab loopTab;

  /// Which tab the Tracks face shows. Kept across navigation, like the others.
  final TracksTab tracksTab;

  /// Which tab the Audio face shows. Kept across navigation, like the others.
  final AudioTab audioTab;

  /// Which tab the System face shows. Kept across navigation, like the rest.
  final SystemTab systemTab;

  /// Which tab the Network face shows. Kept while the tray navigates
  /// elsewhere so returning to Network lands where it was left, and
  /// deliberately not reset by `closeTray`: only [destination] goes home.
  final NetworkTab networkTab;

  /// Returns a copy with the given fields replaced.
  SettingsTrayState copyWith({
    double? dragProgress,
    bool? isNavigating,
    double? brightness,
    SettingsTrayDestination? destination,
    NetworkTab? networkTab,
    ControlTab? controlTab,
    LoopTab? loopTab,
    TracksTab? tracksTab,
    AudioTab? audioTab,
    SystemTab? systemTab,
  }) => SettingsTrayState(
    dragProgress: dragProgress ?? this.dragProgress,
    isNavigating: isNavigating ?? this.isNavigating,
    brightness: brightness ?? this.brightness,
    destination: destination ?? this.destination,
    networkTab: networkTab ?? this.networkTab,
    controlTab: controlTab ?? this.controlTab,
    loopTab: loopTab ?? this.loopTab,
    tracksTab: tracksTab ?? this.tracksTab,
    audioTab: audioTab ?? this.audioTab,
    systemTab: systemTab ?? this.systemTab,
  );

  @override
  List<Object?> get props => [
    dragProgress,
    isNavigating,
    brightness,
    destination,
    networkTab,
    controlTab,
    loopTab,
    tracksTab,
    audioTab,
    systemTab,
  ];
}
