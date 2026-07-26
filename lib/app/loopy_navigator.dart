import 'package:flutter/material.dart';
import 'package:loopy/looper/view/settings_page.dart';
import 'package:loopy/theme/page_transitions.dart';

/// The root navigator key, so settings can be opened from outside the widget
/// tree (e.g. the macOS system menu bar) as well as from in-app gestures.
final GlobalKey<NavigatorState> loopyNavigatorKey = GlobalKey<NavigatorState>();

/// Route name for the settings page (used to avoid stacking duplicates).
const String loopySettingsRouteName = 'loopy/settings';

bool _settingsOpen = false;

/// Pushes the [SettingsPage] onto the root navigator, guarding
/// against stacking duplicates from rapid triggers (menu + key + right-click).
///
/// [section] selects which left-rail tab is shown first (defaults to View).
Future<void> openLoopySettings({
  SettingsSection section = SettingsSection.view,
}) async {
  final navigator = loopyNavigatorKey.currentState;
  if (navigator == null || _settingsOpen) return;
  _settingsOpen = true;
  try {
    await navigator.push(
      desktopPageRoute<void>(
        (_) => SettingsPage(initialSection: section),
        settings: const RouteSettings(name: loopySettingsRouteName),
      ),
    );
  } finally {
    _settingsOpen = false;
  }
}
