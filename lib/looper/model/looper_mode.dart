/// The looper's system-wide interaction mode: what a track press does,
/// wherever the press comes from (pedal footswitch, keyboard, or touch).
///
/// One mode for the whole system — the pedal's MODE footswitch, the keyboard's
/// `M`, and the on-screen mode chip all toggle this same state (owned by
/// `PedalCubit`), so a track press can never mean "record" on one surface and
/// "mute" on another. The pedal wire frame carries it as `PedalMode`.
enum LooperMode {
  /// Track presses select and record/overdub; Stop mutes the selection.
  record,

  /// Track presses arm and mute/unmute; the transport plays the armed set.
  play;

  /// The persisted token for this mode (stable across renames).
  String get token => name;

  /// Parses a persisted [token] back to a mode, defaulting to [record].
  static LooperMode fromToken(String? token) => LooperMode.values.firstWhere(
    (m) => m.name == token,
    orElse: () => LooperMode.record,
  );
}
