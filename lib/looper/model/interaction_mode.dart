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
  mute,

  /// Track presses toggle each track's Track-stage FX chain; the track LEDs
  /// carry chain-enabled state (FX v3 part 5b, pedal protocol v3).
  ///
  /// Every one of the pedal's ten controls is explicitly defined here: the
  /// bank's four track switches stomp Track chains, Stop is FX panic (all
  /// chains off; long-press restores them), Bank / Mode / the encoder keep
  /// their usual jobs, and Rec/Play, Undo and Clear are deliberately INERT —
  /// a stray stomp must never erase the set.
  fx;

  /// The persisted token for this mode. Derived from the member name, so a
  /// member rename changes what new saves write — [fromToken] must keep
  /// accepting every token older builds ever wrote (see its legacy shim).
  String get token => name;

  /// The modes the system may BOOT into. [fx] is excluded on purpose: booting
  /// into FX mode with no chains configured is a dead surface, so it is
  /// reachable only by an explicit mode cycle (R12).
  static const List<InteractionMode> bootDefaults = [record, mute];

  /// Parses a persisted [token] back to a mode, defaulting to [record].
  ///
  /// `'play'` is the pre-rename legacy token for [mute]: this mode was named
  /// `play` before the Sheeran-manual-aligned rename, and existing installs
  /// have `'play'` stored under the `looper.default_mode` settings key. New
  /// saves write `'mute'`. Never remove the shim without a stored-settings
  /// migration.
  ///
  /// This parses EVERY mode, [fx] included; the boot-default path uses
  /// [bootDefaultFromToken], which is the one that enforces R12.
  static InteractionMode fromToken(String? token) {
    if (token == 'play') return InteractionMode.mute;
    return InteractionMode.values.firstWhere(
      (m) => m.name == token,
      orElse: () => InteractionMode.record,
    );
  }

  /// Parses a persisted BOOT-DEFAULT [token]: [fromToken] with anything
  /// outside [bootDefaults] coerced to [record].
  ///
  /// Defensive by design — no build ever writes `'fx'` under the default-mode
  /// key (the settings picker does not offer it), so a stored `'fx'` means a
  /// hand-edited or corrupted pref, and booting a dead surface is the one
  /// outcome R12 forbids.
  static InteractionMode bootDefaultFromToken(String? token) {
    final mode = fromToken(token);
    return bootDefaults.contains(mode) ? mode : InteractionMode.record;
  }
}
