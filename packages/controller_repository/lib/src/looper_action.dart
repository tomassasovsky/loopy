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

  /// Tap to set the tempo (D20).
  tapTempo,

  /// Toggle the click (metronome) mode between off and its last-used
  /// audible mode (D20). Named `toggleMetronome` (not `toggleClick`) per the
  /// index plan's D20 action inventory, matching the deleted pre-`2f0513a`
  /// action's user-facing name; the engine layer itself calls this feature
  /// "click" (`ClickMode`, `TempoControl.setClickMode`).
  toggleMetronome,

  /// Cancel a pending quantized/signal-triggered record arm (D20).
  cancelArm;

  /// Whether this action targets a specific channel (vs a global transport
  /// action like [playAll]).
  bool get isChannelScoped => switch (this) {
    LooperAction.recordOverdub ||
    LooperAction.stop ||
    LooperAction.play ||
    LooperAction.clear ||
    LooperAction.undo => true,
    LooperAction.playAll ||
    LooperAction.stopAll ||
    LooperAction.tapTempo ||
    LooperAction.toggleMetronome ||
    LooperAction.cancelArm => false,
  };
}
