/// Which behavior set the pedal's footswitches drive.
///
/// Serialized as **bit 0 of the state-frame flags byte** (`rec = 0`, `play =
/// 1`) by `PedalCodec`. It is a single wire bit, so this must stay a two-value
/// enum; adding a third *interaction* mode needs a wider field and a protocol
/// bump.
///
/// This is a different axis from the engine's `LooperMode`
/// (Multi/Sync/Song/Band/Free — what the looper's transport *is*), which
/// protocol v2 carries separately as `PedalLooperMode` in bits 4-6 of the
/// *same* flags byte (D11). [PedalMode] itself is untouched by that bump —
/// it stays the same single wire bit it always was. The two enums must not
/// be confused with each other; see `PedalLooperMode`'s doc comment (and
/// D10, which performed the equivalent split on the app side:
/// `InteractionMode` vs. `LooperMode`).
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
