/// Which tab the Loop domain is showing.
///
/// Flutter-free, like `NetworkTab` and `ControlTab` and for the same reason:
/// the value lives in `SettingsTrayState`, and the tray cubit must not import
/// a widget library to name something it only stores.
enum LoopTab {
  /// The tempo grid — tempo, signature, loop length, quantise, count-in.
  tempo,

  /// The click: when it sounds, where it goes, how loud.
  click,

  /// The looper-mode axis and the boot default.
  mode,
}
