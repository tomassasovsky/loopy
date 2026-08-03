/// Metrics shared between the tray shell and the panel it opens.
///
/// These exist because two widgets in different files have to agree about the
/// same pixels. Anything only one file needs stays private to that file.
library;

/// Rendered height of the tray's drag handle.
///
/// `SettingsTray` positions the handle at the open panel's bottom edge, where
/// it paints *over* the panel's own content; the navigation rail pads its
/// scroll view past this so a rail item can never sit under a control that
/// closes the tray. Both read this constant, so the two cannot drift.
const double kTrayHandleHeight = 21;
