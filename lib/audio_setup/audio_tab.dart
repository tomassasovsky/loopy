/// Which face the console's Audio domain is showing.
///
/// The reorganised IA (#498) gathers the rig's audio under one rail entry:
/// what it is playing through, what it does when you record, and what it is
/// actually doing right now.
///
/// Flutter-free, like `LoopTab` and `TracksTab`: the tray cubit holds the
/// selected tab and must not import a widget library to name a value it
/// stores.
enum AudioTab {
  /// Device, sample rate and buffer, named inputs.
  device,

  /// Loop length caps, quantize, overdub and sound-activated recording.
  recording,

  /// What the engine reports, and the latency measurement.
  status,
}
