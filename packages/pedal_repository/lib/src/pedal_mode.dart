/// Which behavior set the pedal's footswitches drive.
///
/// Serialized as **bit 0 of the state-frame flags byte** (`rec = 0`, `play =
/// 1`) by `PedalCodec`. It is a single wire bit, so this must stay a two-value
/// enum; adding a third mode needs a wider field and a protocol bump.
enum PedalMode {
  /// Recording / transport control.
  ///
  /// The track buttons select the cursor track; Rec/Play cycles the selected
  /// track through record / overdub / play; Stop mutes it.
  rec,

  /// Mixing / playback control.
  ///
  /// While playing, the track buttons mute/unmute; while stopped (parked) they
  /// arm/disarm the play set. Rec/Play plays the armed set or stops everything.
  play,
}
