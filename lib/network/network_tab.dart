/// Which radio the Network domain is showing.
///
/// **Not a destination.** The rail carries one Network entry; which of its two
/// faces is up is a property of that entry, held by `SettingsTrayCubit` so a
/// shortcut can open the domain *at* a tab and returning to it lands where it
/// was left.
///
/// Lives in its own Flutter-free file because the tray cubit holds the value
/// and the panel draws the strip: a cubit must not import a widget library to
/// name something it stores.
enum NetworkTab {
  /// The WiFi face.
  wifi,

  /// The Bluetooth face.
  bluetooth,
}
