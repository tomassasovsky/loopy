/// Which tab the Audio domain is showing.
///
/// Flutter-free, like `LoopTab`, `ControlTab` and `TracksTab` and for the same
/// reason: the value lives in `SettingsTrayState`, and the tray cubit must not
/// import a widget library to name something it only stores.
///
/// The split is one question asked three ways. [device] is what the rig plays
/// through and how fast it runs, [recording] is what pressing record does, and
/// [status] is what the rig is actually doing right now.
enum AudioTab {
  /// The device, its rate and buffer, and what its inputs are called.
  device,

  /// What pressing record does: the loop cap, quantize, overdub, sound-
  /// activated recording, and the default length.
  recording,

  /// Read-only: what the engine currently reports, and the one action that
  /// re-runs the latency measurement.
  status,
}
