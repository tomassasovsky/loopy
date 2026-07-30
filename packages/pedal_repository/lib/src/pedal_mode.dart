/// Which behavior set the pedal's footswitches drive.
///
/// Serialized as a **2-bit field** by `PedalCodec` since protocol v3: the low
/// bit is the state-frame flags byte's bit 0 (`rec = 0`, `play = 1` — the
/// original single-bit wire), and the high bit lives in bit 1 of the
/// active-bank payload byte (byte 2), which had 7 spare bits. This enum was
/// deliberately two-valued through v1/v2 ("adding a third *interaction* mode
/// needs a wider field and a protocol bump") — v3 is exactly that bump, made
/// without growing the 17-byte payload. The fourth wire value (`0b11`) is
/// reserved: the decoder rejects it like any other out-of-range enum index.
///
/// On a v1/v2 wire only the low bit exists, so those frames can never decode
/// to [fx]; encoding a frame whose mode is [fx] at v1/v2 writes the mode bit
/// as [play] (mute) and every other byte exactly as the v3 encoding would —
/// the B10 downgrade projection for pedals that predate v3.
///
/// This is a different axis from the engine's `LooperMode`
/// (Multi/Sync/Song/Band/Free — what the looper's transport *is*), which
/// protocol v2 carries separately as `PedalLooperMode` in bits 4-6 of the
/// flags byte (D11). The two enums must not be confused with each other; see
/// `PedalLooperMode`'s doc comment (and D10, which performed the equivalent
/// split on the app side: `InteractionMode` vs. `LooperMode`).
///
/// Encoded as the enum [index] in the state frame — **do not reorder**; the
/// declaration order is the wire value and must stay in lockstep with the
/// firmware's explicit `PEDAL_MODE_*` constants (`pedal_protocol.h`).
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

  /// Effects control (protocol v3).
  ///
  /// The track buttons toggle each track's FX chain; the LEDs carry
  /// chain-enabled state (`PedalTrackLed.blue`). The app-side button matrix
  /// and LED projection are part 5b's — the codec only carries the mode.
  fx,
}
