/// The settings tray's open sheet: a navigation rail plus the face it
/// selects.
///
/// Only `TrayPanel` leaves this folder — `SettingsTray` mounts it and nothing
/// else outside needs the rail, the faces, or the tiles. Later parts of the
/// console redesign (#442) add faces here; they do not widen this barrel.
library;

export 'tray_panel.dart' show TrayPanel;
