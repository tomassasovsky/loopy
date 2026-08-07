/// The settings tray's open sheet: a navigation rail plus the face it
/// selects.
///
/// `TrayPanel` and the metrics the shell shares with it are all that leave
/// this folder — `SettingsTray` mounts the panel and needs the handle height
/// the rail also reads; nothing outside needs the rail, the faces, or the
/// tiles. Later parts of the console redesign (#442) add faces here; they do
/// not widen this barrel.
library;

export 'tray_metrics.dart'
    show kTrayHandleHeight, kTrayHandlePill, kTraySheetRadius;
export 'tray_panel.dart' show TrayPanel;
