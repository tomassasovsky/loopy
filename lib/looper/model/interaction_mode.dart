/// The looper's system-wide interaction mode: what a track press does,
/// wherever the press comes from (pedal footswitch, keyboard, or touch).
///
/// One mode for the whole system — the pedal's MODE footswitch, the keyboard's
/// `M`, and the on-screen mode chip all toggle this same state (owned by
/// `ControlCubit`), so a track press can never mean "record" on one surface and
/// "mute" on another. The pedal wire frame carries it as `PedalMode`.
enum InteractionMode {
  /// Track presses select and record/overdub; Stop mutes the selection.
  record,

  /// Track presses arm and mute/unmute; the transport plays the armed set.
  ///
  /// Named after the Sheeran Looper X manual's "Mute Mode" — the track-press
  /// action in this mode is mute toggling.
  mute;

  /// The persisted token for this mode. Derived from the member name, so a
  /// member rename changes what new saves write — [fromToken] must keep
  /// accepting every token older builds ever wrote (see its legacy shim).
  String get token => name;

  /// Parses a persisted [token] back to a mode, defaulting to [record].
  ///
  /// `'play'` is the pre-rename legacy token for [mute]: this mode was named
  /// `play` before the Sheeran-manual-aligned rename, and existing installs
  /// have `'play'` stored under the `looper.default_mode` settings key. New
  /// saves write `'mute'`. Never remove the shim without a stored-settings
  /// migration.
  static InteractionMode fromToken(String? token) {
    if (token == 'play') return InteractionMode.mute;
    return InteractionMode.values.firstWhere(
      (m) => m.name == token,
      orElse: () => InteractionMode.record,
    );
  }
}
