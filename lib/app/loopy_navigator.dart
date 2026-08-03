import 'package:flutter/material.dart';
import 'package:loopy/app/app_toasts.dart';
import 'package:loopy/looper/view/settings_page.dart';
import 'package:loopy/theme/page_transitions.dart';

/// The root navigator key, so settings can be opened from outside the widget
/// tree (e.g. the macOS system menu bar) as well as from in-app gestures.
final GlobalKey<NavigatorState> loopyNavigatorKey = GlobalKey<NavigatorState>();

/// Route name for the settings page (used to avoid stacking duplicates).
const String loopySettingsRouteName = 'loopy/settings';

bool _settingsOpen = false;

/// Clears the "settings already open" guard.
///
/// The guard is module-level and only released when the route pops, so a
/// widget test that leaves settings open wedges it for every later test in the
/// file — `openLoopySettings` then returns early and the page never appears.
@visibleForTesting
void resetLoopyNavigatorForTest() {
  _settingsOpen = false;
  _openSettingsSection = null;
}

SettingsSection? _openSettingsSection;

/// Whether Settings is open on the Updates tab (skip the update toast).
bool get isLoopyUpdatesSettingsOpen =>
    _settingsOpen && _openSettingsSection == SettingsSection.updates;

void _onSettingsSectionChanged(SettingsSection section) {
  _openSettingsSection = section;
  if (section == SettingsSection.updates) {
    dismissAppToast(AppToastId.update);
  }
}

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
  _openSettingsSection = section;
  if (section == SettingsSection.updates) {
    dismissAppToast(AppToastId.update);
  }
  try {
    await navigator.push(
      desktopPageRoute<void>(
        (_) => SettingsPage(
          initialSection: section,
          onSectionChanged: _onSettingsSectionChanged,
        ),
        settings: const RouteSettings(name: loopySettingsRouteName),
      ),
    );
  } finally {
    _settingsOpen = false;
    _openSettingsSection = null;
  }
}
