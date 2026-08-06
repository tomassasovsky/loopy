/// Which face the console's Loop domain is showing.
///
/// The reorganised IA (#498) gathers everything that governs the loop grid
/// under one rail entry: what the tempo is, what the click does about it, and
/// which looper mode the tracks obey.
///
/// Flutter-free, like `NetworkTab` and `ControlTab`: the tray cubit holds the
/// selected tab and must not import a widget library to name a value it
/// stores.
enum LoopTab {
  /// Tempo, time signature, loop length, quantise, count-in, sync.
  tempo,

  /// When the metronome plays, where it goes, how loud.
  click,

  /// The looper mode, one-shot tracks, and the boot default.
  mode,
}
