/// How a bound switch behaves while it is held down.
///
/// The ONE behavior vocabulary every control surface shares: the pedal's
/// footswitch remap (part 6b) and a discrete on/off MIDI CC (part 7) mean the
/// same two things by these names, so a generic MIDI footswitch — and the
/// TRS jack that follows — needs no vocabulary of its own.
///
/// It lives in this package rather than app-side because it is the one piece
/// of the binding model the repositories themselves must carry: a binding is
/// persisted here, and its behavior rides with it. The TARGET stays opaque
/// (a canonical-JSON string), so this package still gains no looper/engine
/// dependency.
enum BindingBehavior {
  /// Press flips the target's `enabled` flag and it STAYS flipped — the
  /// stompbox reading, and what an unbound FX-mode track button already does.
  toggle,

  /// Press enables the target, release puts it back the way it was — the
  /// "hold for the solo boost" reading. The press captures the target's
  /// current state and the release writes that capture back, so a held switch
  /// can never outlive its press.
  momentary;

  /// Maps a persisted [name] back to a behavior, defaulting to [toggle] —
  /// the safe reading for an unknown value, since a momentary that never
  /// releases is the failure mode worth avoiding.
  static BindingBehavior fromName(String? name) {
    for (final behavior in values) {
      if (behavior.name == name) return behavior;
    }
    return toggle;
  }
}
