/// Metrics shared between the tray shell and the panel it opens.
///
/// These exist because two widgets in different files have to agree about the
/// same pixels. Anything only one file needs stays private to that file.
library;

import 'package:flutter/animation.dart';

/// Rendered height of the tray's drag handle.
///
/// `SettingsTray` positions the handle at the open panel's bottom edge, where
/// it paints *over* the panel's own content; the navigation rail pads its
/// scroll view past this so a rail item can never sit under a control that
/// closes the tray. Both read this constant, so the two cannot drift.
const double kTrayHandleHeight = 21;

/// Radius of the sheet's bottom corners, measured off the mockups' tray layer.
///
/// Beside [kTrayHandleHeight] rather than private to `tray_panel.dart`: the
/// sheet and the handle that rides at its bottom edge are one shape drawn by
/// two files, and the corner is the part of it a reader of either file would
/// otherwise have to guess.
const double kTraySheetRadius = 17;

/// Size of the drag handle's pill, as the mockups draw it.
const Size kTrayHandlePill = Size(62, 5);

/// How long the sheet takes to slide open or shut on a tap.
///
/// Here rather than private to `settings_tray.dart` because the sheet's own
/// cast shadow has to fade over exactly this, on exactly this curve: a shadow
/// driven straight off `dragProgress` — which a tap snaps between 0 and 1 in
/// one frame — pops off a sheet that is still sliding.
const Duration kTrayMotion = Duration(milliseconds: 220);

/// The curve the slide follows, and so the curve the shadow fades on.
const Curve kTrayMotionCurve = Curves.easeOut;
