/// Which radio the Network domain is showing.
///
/// The reorganised console IA (#498) gives the two radios one rail entry with
/// a tab strip instead of two rail entries, so "which radio" stops being a
/// destination and becomes a tab within one.
///
/// Lives in its own file, free of Flutter imports, because both the tray cubit
/// (which holds the selected tab) and the panel (which draws the strip) need
/// it — and the cubit must not import a widget library to name a value it
/// stores.
enum NetworkTab {
  /// WiFi status, scan and join.
  wifi,

  /// Bluetooth power, discoverability and paired devices.
  bluetooth,
}
