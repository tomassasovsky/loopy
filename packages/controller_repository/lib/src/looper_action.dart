/// A hardware-agnostic looper action a controller can trigger.
///
/// Footswitches/pads/pins are mapped to these via a `ControllerMapping`; the
/// bloc layer translates them into looper commands.
enum LooperAction {
  /// Toggle record → finalize loop → overdub on the target channel.
  recordOverdub,

  /// Stop the target channel.
  stop,

  /// Play the target channel.
  play,

  /// Clear the target channel.
  clear,

  /// Undo the last overdub on the target channel.
  undo,

  /// Play all tracks.
  playAll,

  /// Stop all tracks.
  stopAll,

  /// Tap to set the tempo.
  tapTempo;

  /// Whether this action targets a specific channel (vs a global transport
  /// action like [playAll] or [tapTempo]).
  bool get isChannelScoped => switch (this) {
    LooperAction.recordOverdub ||
    LooperAction.stop ||
    LooperAction.play ||
    LooperAction.clear ||
    LooperAction.undo => true,
    LooperAction.playAll ||
    LooperAction.stopAll ||
    LooperAction.tapTempo => false,
  };
}
