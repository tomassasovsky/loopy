/// Which face the console's System domain is showing.
///
/// Flutter-free, like the other domains' tab enums: the tray cubit holds the
/// selected tab and must not import a widget library to name a value it
/// stores.
///
/// The mockups draw four — Display, Updates, Storage and About. Only the two
/// the app can actually answer are here; Storage needs disk reporting and
/// housekeeping that do not exist, and About needs console identity nobody
/// records yet (#530). A tab that opens onto nothing is worse than a tab that
/// is not there yet.
enum SystemTab {
  /// Waveform window, contrast, indicators, refresh rate, shortcuts.
  display,

  /// Version, channel, the automatic switches, and the update flow.
  updates,
}
