part of 'settings_tray_cubit.dart';

/// Which face the open tray is showing — home tiles, or one of the in-tray
/// config panels (Control-Center expand, not a full-screen route).
///
/// Every value here is a destination the tray's own navigation rail can
/// select. Settings still pushes a full-screen route and so deliberately has
/// no value: a rail item that navigates away would lie about what the rail is.
///
/// Later parts of the console redesign (#442) each add their own value here
/// alongside the panel that fills it — the enum is not pre-populated with
/// placeholders, because a rail item that does nothing when tapped is worse
/// than a two-line enum edit.
enum SettingsTrayDestination {
  /// Tile grid + brightness.
  home,

  /// In-tray Signal domain — the four FX stages as tabs of one entry.
  ///
  /// **First of the domains**, as the mockups draw the rail: the signal path
  /// is what the rest of the console configures, so it reads before the things
  /// that drive it.
  ///
  /// One destination, not four: the tabs are [FxStage] itself — the app's own
  /// FX addressing model, `input · loop · track · master` in signal order — so
  /// this domain does not own a tab enum of its own the way its six siblings
  /// do. A tab here selects which STAGE's chains you are looking at, and every
  /// card on every tab is one chain.
  ///
  /// This is the destination that closed the rail's last exception. Signal was
  /// a tile on the home face pushing a full-screen route, which #533 replaced
  /// with the face beside the rail.
  signal,

  /// In-tray Control domain — the footswitch plate and the MIDI foot
  /// controller as tabs of one entry.
  ///
  /// One destination, not two: both tabs answer the same question — *what
  /// outside this box is driving it?* — and they had been in two different
  /// places, one a rail entry of its own (#440) and the other a group buried
  /// in the Settings scroll. Which one is showing is
  /// [SettingsTrayState.controlTab], not a destination of its own.
  control,

  /// In-tray Loop domain — the tempo grid, the click and the looper mode as
  /// tabs of one entry.
  ///
  /// One destination, not three: all three tabs answer the same question —
  /// *what governs the loop grid?* — and they had been split between a Loop
  /// rail entry and two groups of the Settings scroll (#518). Which tab is
  /// showing is [SettingsTrayState.loopTab], not a destination of its own.
  loop,

  /// In-tray Tracks domain — names, lengths and routing as tabs of one entry.
  ///
  /// One destination, not three: all three tabs answer the same question —
  /// *what is each track, and where does it go?* — and they had been split
  /// between the Settings scroll's `tracks` section, the Signal page and, for
  /// the quantize override, nowhere at all (#523).
  ///
  /// The difference from [control] and [loop] is what a ROW means: there a row
  /// is a global setting, here every row on all three tabs is a **track**, and
  /// the engine's own roster drives all three lists. That is why this domain
  /// is the one that needed an empty state — a face whose rows are objects can
  /// have none of them.
  tracks,

  /// In-tray Audio domain — the device, what recording does, and what the
  /// rig is currently doing, as tabs of one entry.
  ///
  /// One destination, not three: all three tabs answer the same question three
  /// ways — what the rig plays through, what pressing record does, and what it
  /// is actually doing right now (#528). They had been one group of the
  /// Settings scroll, `SettingsSection.audio`.
  ///
  /// Status is the tab that makes the split worth having: everything on it is
  /// read-only, because the settings that decide those figures live on Device,
  /// and a figure editable in two places is a figure that disagrees with
  /// itself.
  audio,

  /// In-tray tuner panel. Placement only — the tuner itself is not
  /// implemented, and this face says so.
  tuner,

  /// In-tray Network domain — WiFi and Bluetooth as tabs of one entry.
  ///
  /// One destination, not two: two rail slots for two radios was the same
  /// waste as one Settings bucket for twelve groups (#498). Which radio is
  /// showing is [SettingsTrayState.networkTab], not a destination of its own.
  network,

  /// In-tray System domain — what the screens do, what build is running, what
  /// is on the disk, and what this box is, as tabs of one entry.
  ///
  /// One destination, not four: all four answer the same question — *what is
  /// this console, and how does it behave?* Two of them were groups of the
  /// Settings scroll (`SettingsSection.view` and `.updates`); the other two
  /// had nowhere to live at all, because nothing in the app knew what the
  /// disk held or what the box was called (#530).
  system,
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
    this.signalTab = FxStage.input,
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
  /// route pops — so a rapid double-tap cannot push the same route twice, and
  /// so the tile reads as disabled while its route is on its way up.
  final bool isNavigating;

  /// Brightness slider value (`0..1`). Persisted via SettingsRepository;
  /// applied through BrightnessClient when DDC/CI is available.
  final double brightness;

  /// In-tray face: home tiles or one of the rail's domain panels.
  final SettingsTrayDestination destination;

  /// Which FX stage the Signal domain shows.
  ///
  /// Typed as [FxStage] rather than a `SignalTab` of its own: the four tabs
  /// the mockups draw *are* the four stages the app already addresses chains
  /// by, in the same order, so a parallel enum would be a second name for one
  /// thing — and the one that could drift.
  ///
  /// Starts on [FxStage.input], the head of the signal path.
  final FxStage signalTab;

  /// Which tab the Network domain shows.
  ///
  /// Survives leaving and returning to the domain — closing the tray resets
  /// [destination] and deliberately not this, so Network lands where it was
  /// left.
  final NetworkTab networkTab;

  /// Which tab the Control domain shows. Same rule as [networkTab].
  final ControlTab controlTab;

  /// Which tab the Loop domain shows. Same rule as [networkTab].
  final LoopTab loopTab;

  /// Which tab the Tracks domain shows. Same rule as [networkTab].
  final TracksTab tracksTab;

  /// Which tab the Audio domain shows. Same rule as [networkTab].
  final AudioTab audioTab;

  /// Which tab the System domain shows. Same rule as [networkTab].
  final SystemTab systemTab;

  /// Returns a copy with the given fields replaced.
  SettingsTrayState copyWith({
    double? dragProgress,
    bool? isNavigating,
    double? brightness,
    SettingsTrayDestination? destination,
    FxStage? signalTab,
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
    signalTab: signalTab ?? this.signalTab,
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
    signalTab,
    networkTab,
    controlTab,
    loopTab,
    tracksTab,
    audioTab,
    systemTab,
  ];
}
