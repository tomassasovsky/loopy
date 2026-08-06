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

/// The tray's bottom corner radius, off the mockups' tray layer.
const double kTrayRadius = 17;

/// The drag handle's pill: 62x5 in a 31px band, as every `AREA / *` screen
/// draws it.
const double kTrayHandlePillWidth = 62;
const double kTrayHandlePillHeight = 5;
