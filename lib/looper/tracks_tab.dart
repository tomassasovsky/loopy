/// Which tab the console's Tracks face is showing.
///
/// Flutter-free so the tray cubit can hold it without importing a view: the
/// same shape as `LoopTab` and `ControlTab`.
enum TracksTab {
  /// Rename the tracks.
  names,

  /// Per-track loop length: auto, or a bar preset.
  lengths,

  /// Per-track input, outputs and quantize override.
  routing,
}
