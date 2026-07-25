import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/settings_tray_cubit.dart';
import 'package:loopy/looper/view/coming_soon_stub.dart';
import 'package:loopy/looper/view/signal_graph/signal_graph.dart';
import 'package:loopy/theme/theme.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

/// The console's slide-down quick-access tray (Control-Center style): a small
/// pull-tab [_TrayHandle] pinned at the top edge at all times — tap or drag
/// it down to reveal Settings, Signal/FX graph, WiFi/Bluetooth/Tuner stubs,
/// and a local brightness slider; tap the scrim or swipe up to dismiss.
///
/// Overlaid as a `Stack` sibling of `TracksView`'s content (see
/// `tracks_view.dart`), not a route — it paints over the tracks grid rather
/// than navigating away from it.
class SettingsTray extends StatefulWidget {
  /// Creates a [SettingsTray].
  const SettingsTray({super.key});

  @override
  State<SettingsTray> createState() => _SettingsTrayState();
}

class _SettingsTrayState extends State<SettingsTray> {
  /// The tray panel's fully-open height — sized for one row of five shortcut
  /// buttons plus the brightness slider.
  static const double _kTrayHeight = 200;

  /// True for the lifetime of a handle drag. While true, the panel height and
  /// scrim opacity track the pointer with no animation (every frame is a
  /// fresh, instant target); once the drag ends the next change animates,
  /// giving the settle its motion. A tap-triggered toggle (no drag) always
  /// animates.
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<SettingsTrayCubit>().state;
    final cubit = context.read<SettingsTrayCubit>();
    final motion = _dragging || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);

    return Stack(
      children: [
        // The scrim: dismisses on tap, hit-testable (and in the semantics
        // tree — IgnorePointer.ignoringSemantics mirrors `ignoring` by
        // default) only once the tray has any visible extent, so it never
        // blocks touches to TracksView, or a screen reader's tap-to-dismiss,
        // while fully closed.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: state.dragProgress <= 0,
            child: GestureDetector(
              key: const Key('settingsTray_scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: cubit.closeTray,
              child: Semantics(
                button: true,
                label: l10n.dismiss,
                child: AnimatedOpacity(
                  duration: motion,
                  opacity: state.dragProgress * 0.5,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Column(
            children: [
              _TrayHandle(
                onDragStart: () => setState(() => _dragging = true),
                // Reads `cubit.state` (always current) rather than the
                // `state` closed over from this build — several pointer-move
                // events can fire back-to-back before the next rebuild, and
                // accumulating from a build-time snapshot would drop all but
                // the last delta in that batch instead of summing them.
                onDragUpdate: (dy) => cubit.dragTo(
                  cubit.state.dragProgress + dy / _kTrayHeight,
                ),
                onDragEnd: () {
                  cubit.settleFromDrag();
                  setState(() => _dragging = false);
                },
                onTap: cubit.toggle,
              ),
              AnimatedContainer(
                duration: motion,
                curve: Curves.easeOut,
                height: state.dragProgress.clamp(0.0, 1.0) * _kTrayHeight,
                child: ClipRect(
                  child: OverflowBox(
                    minHeight: _kTrayHeight,
                    maxHeight: _kTrayHeight,
                    alignment: Alignment.topCenter,
                    // Clipped to zero height while closed (and hit-testing
                    // with it, via ClipRect) — also drop it from the
                    // semantics tree then, so a screen reader never lands on
                    // buttons with no visible extent.
                    child: ExcludeSemantics(
                      excluding: state.dragProgress <= 0,
                      child: _TrayPanel(
                        brightness: state.brightness,
                        isNavigating: state.isNavigating,
                        onBrightnessChanged: cubit.setBrightness,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The always-visible pull tab pinned at the top edge. Owns ALL drag
/// recognition for the tray — confined here (rather than spread over the
/// full tray body) so the brightness `Slider` inside the open panel owns its
/// own gesture arena outright, with no competing recognizer over its hit
/// area. If a future change widens the tray's own drag region, that
/// isolation breaks silently — keep drag handling on this widget alone.
class _TrayHandle extends StatelessWidget {
  const _TrayHandle({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
  });

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: l10n.a11yTrayHandle,
      child: GestureDetector(
        key: const Key('settingsTray_handle'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => onDragStart(),
        onVerticalDragUpdate: (details) => onDragUpdate(details.delta.dy),
        onVerticalDragEnd: (_) => onDragEnd(),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tray's contents once open: a row of shortcut buttons (Settings,
/// Signal/FX, WiFi, Bluetooth, Tuner) and the brightness slider.
class _TrayPanel extends StatelessWidget {
  const _TrayPanel({
    required this.brightness,
    required this.isNavigating,
    required this.onBrightnessChanged,
  });

  final double brightness;
  final bool isNavigating;
  final ValueChanged<double> onBrightnessChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Both nav buttons disable for the duration of a pending
                  // push: functionally required for Signal (`showSignalPage`
                  // has no re-entrancy guard of its own — a rapid double-tap
                  // would double-push it), and applied to Settings too for
                  // UX consistency — `openLoopySettings` self-guards against
                  // a real double-push, but leaving its button tappable
                  // mid-push would still look live when it isn't.
                  _TrayButton(
                    key: const Key('settingsTray_settings'),
                    icon: Icons.settings_outlined,
                    label: l10n.settingsTooltip,
                    onTap: isNavigating
                        ? null
                        : () => unawaited(
                            _navigate(context, openLoopySettings),
                          ),
                  ),
                  _TrayButton(
                    key: const Key('settingsTray_signal'),
                    icon: Icons.account_tree_outlined,
                    label: l10n.signalTooltip,
                    onTap: isNavigating
                        ? null
                        : () => unawaited(
                            _navigate(context, () => showSignalPage(context)),
                          ),
                  ),
                  _TrayButton(
                    key: const Key('settingsTray_wifi'),
                    icon: Icons.wifi,
                    label: l10n.trayWifiLabel,
                    onTap: () => unawaited(
                      showComingSoonStub(context, feature: l10n.trayWifiLabel),
                    ),
                  ),
                  _TrayButton(
                    key: const Key('settingsTray_bluetooth'),
                    icon: Icons.bluetooth,
                    label: l10n.trayBluetoothLabel,
                    onTap: () => unawaited(
                      showComingSoonStub(
                        context,
                        feature: l10n.trayBluetoothLabel,
                      ),
                    ),
                  ),
                  _TrayButton(
                    key: const Key('settingsTray_tuner'),
                    icon: Icons.graphic_eq,
                    label: l10n.trayTunerLabel,
                    onTap: () => unawaited(
                      showComingSoonStub(context, feature: l10n.trayTunerLabel),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.brightness_6_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Slider(
                      key: const Key('settingsTray_brightness'),
                      value: brightness,
                      label: l10n.trayBrightnessLabel,
                      semanticFormatterCallback: (value) =>
                          '${l10n.trayBrightnessLabel} '
                          '${(value * 100).round()}%',
                      onChanged: onBrightnessChanged,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs a tray nav-button push (`openLoopySettings` or `showSignalPage`,
/// unchanged from the `S`/`G` keyboard shortcuts and desktop toolbar).
/// Closes the tray synchronously — before [push] resolves — and holds the
/// `isNavigating` guard for the push's duration even if it throws, so a
/// failed navigation can never leave both nav buttons stuck disabled.
Future<void> _navigate(
  BuildContext context,
  Future<void> Function() push,
) async {
  final cubit = context.read<SettingsTrayCubit>()
    ..closeTray()
    ..beginNavigating();
  try {
    await push();
  } finally {
    if (context.mounted) cubit.endNavigating();
  }
}

/// One tray shortcut: an icon over a short label, focusable and
/// screen-reader operable via [FocusableTapTarget]. Null [onTap] renders
/// dimmed and inert (used while a nav push from this tray is in flight).
class _TrayButton extends StatelessWidget {
  const _TrayButton({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final toolbarIconColor = Theme.of(
      context,
    ).extension<LooperTheme>()!.toolbarIconColor;
    final color = onTap == null
        ? toolbarIconColor.withValues(alpha: 0.4)
        : toolbarIconColor;
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: 10,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
