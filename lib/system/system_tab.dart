/// Which face the console's System domain is showing.
///
/// Flutter-free, like the other domains' tab enums: the tray cubit holds the
/// selected tab and must not import a widget library to name a value it
/// stores.
///
/// All four the mockups draw. Storage and About report facts that only the
/// appliance image has; off the appliance they come from a fake behind the
/// same `SEGNO_FAKE_RADIOS` define the radios use, so the faces can be seen
/// and driven from a desktop, and say plainly when a build cannot answer.
enum SystemTab {
  /// Waveform window, contrast, indicators, refresh rate, shortcuts.
  display,

  /// Version, channel, the automatic switches, and the update flow.
  updates,

  /// What is using the disk, and the two housekeeping actions.
  storage,

  /// What this console is, what it runs, and the legal line.
  about,
}
