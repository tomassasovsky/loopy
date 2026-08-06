/// Which tab the Control domain is showing.
///
/// Flutter-free, like `NetworkTab` and for the same reason: the value lives in
/// `SettingsTrayState`, and the tray cubit must not import a widget library to
/// name something it only stores.
enum ControlTab {
  /// The footswitch plate's assignable switches and what they act on.
  pedal,

  /// The MIDI foot controller, and every global mapping off it.
  midi,
}
