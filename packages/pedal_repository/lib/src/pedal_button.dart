/// A physical control on the looper pedal.
///
/// Each button maps to one fixed MIDI note number (see [PedalButtonNote]); the
/// pedal fires NoteOn on press and NoteOff (or NoteOn velocity 0) on release.
/// loopy times tap / long-press / double-tap from the press/release pair.
///
/// The note assignment is part of the wire contract shared with the firmware —
/// do not renumber existing entries.
enum PedalButton {
  /// Record / Play footswitch (the cycling transport button).
  recPlay,

  /// Stop footswitch.
  stop,

  /// Undo footswitch (long-press = redo, derived in loopy).
  undo,

  /// Mode footswitch — toggles the pedal between Rec and Play behavior.
  mode,

  /// Track 1 footswitch.
  track1,

  /// Track 2 footswitch.
  track2,

  /// Track 3 footswitch.
  track3,

  /// Track 4 footswitch.
  track4,

  /// Clear-all footswitch.
  clear,

  /// Bank toggle footswitch (A/B).
  bank,
}

/// The fixed MIDI note number assigned to each [PedalButton].
///
/// This table is the inbound half of the pedal protocol contract: the firmware
/// sends these notes, loopy decodes them. Numbers are stable; appending a new
/// button must use the next free note rather than reshuffling.
extension PedalButtonNote on PedalButton {
  /// The MIDI note number this button transmits.
  int get note => index;

  /// The [PedalButton] for a MIDI [note], or `null` if it is unassigned.
  static PedalButton? fromNote(int note) {
    if (note < 0 || note >= PedalButton.values.length) return null;
    return PedalButton.values[note];
  }
}
