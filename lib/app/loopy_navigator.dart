import 'package:flutter/material.dart';
import 'package:loopy/looper/view/big_picture_settings_page.dart';

/// The root navigator key, so settings can be opened from outside the widget
/// tree (e.g. the macOS system menu bar) as well as from in-app gestures.
final GlobalKey<NavigatorState> loopyNavigatorKey = GlobalKey<NavigatorState>();

/// Route name for the settings page (used to avoid stacking duplicates).
const String loopySettingsRouteName = 'loopy/settings';

bool _settingsOpen = false;

/// Pushes the [BigPictureSettingsPage] onto the root navigator, guarding
/// against stacking duplicates from rapid triggers (menu + key + right-click).
Future<void> openLoopySettings() async {
  final navigator = loopyNavigatorKey.currentState;
  if (navigator == null || _settingsOpen) return;
  _settingsOpen = true;
  try {
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const BigPictureSettingsPage(),
        settings: const RouteSettings(name: loopySettingsRouteName),
      ),
    );
  } finally {
    _settingsOpen = false;
  }
}
