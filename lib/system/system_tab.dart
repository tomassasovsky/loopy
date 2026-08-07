/// Which tab the System domain is showing.
///
/// Flutter-free, like `AudioTab`, `LoopTab`, `ControlTab` and `TracksTab` and
/// for the same reason: the value lives in `SettingsTrayState`, and the tray
/// cubit must not import a widget library to name something it only stores.
///
/// Four tabs, which is one more than any other domain — so each was checked
/// against the rule the Audio slice arrived at, that **a tab which only
/// reports is suspect**. [display] and [updates] are settings. [storage] is
/// five readouts and two actions, and the readouts are the argument for the
/// actions rather than a report of their own. [about] is the only pure
/// readout on the console, and it earns that because there is nowhere else
/// the serial of the box you are standing over could go.
enum SystemTab {
  /// What the screens do: the second waveform window, high contrast, track
  /// indicators, the UI refresh rate, and the shortcut legend.
  display,

  /// The installed build, the channel, what happens automatically, and the
  /// check/download/restart flow.
  updates,

  /// What is using the disk, and the two housekeeping actions.
  storage,

  /// What this console is, what hardware it has, and the legal line.
  about,
}
