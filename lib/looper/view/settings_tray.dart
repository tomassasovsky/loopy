import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/settings_tray_cubit.dart';
import 'package:loopy/looper/view/coming_soon_stub.dart';
import 'package:loopy/looper/view/signal_graph/signal_graph.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
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
  /// The tray panel's fully-open height — sized for one row of five badged
  /// shortcut buttons, the divider, and the brightness slider.
  static const double _kTrayHeight = 232;

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
                progress: state.dragProgress.clamp(0.0, 1.0),
                duration: motion,
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
    required this.progress,
    required this.duration,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
  });

  /// Live/settled drag progress (`0..1`) — brightens the tab and turns its
  /// chevron as the tray opens, so the handle itself previews the motion
  /// rather than sitting as a static affordance.
  final double progress;

  /// Reduced-motion-aware duration for the chevron's rotation and the tab's
  /// colour lerp (zero during an active drag, so both track the pointer).
  final Duration duration;

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final tint = Color.lerp(surface.textTertiary, surface.accent, progress)!;
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
          padding: const EdgeInsets.only(bottom: 6),
          color: Colors.transparent,
          alignment: Alignment.topCenter,
          // A small protruding tab (rather than a bare line floating on the
          // tracks grid) — reads as a physical pull, and its own drop shadow
          // separates it from whatever's directly behind it.
          child: AnimatedContainer(
            duration: duration,
            padding: const EdgeInsets.fromLTRB(16, 7, 12, 7),
            decoration: BoxDecoration(
              color: surface.card,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
              border: Border.all(color: surface.line),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: duration,
                  width: 28,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedRotation(
                  duration: duration,
                  turns: progress > 0.5 ? 0.5 : 0,
                  curve: Curves.easeOut,
                  child: Icon(Icons.keyboard_arrow_down, size: 16, color: tint),
                ),
              ],
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
    final surface = context.surface;
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        // A little vertical depth (cardHigh -> card) so the panel reads as
        // a raised instrument-panel surface rather than a flat sheet, matching
        // the Signal surface's chrome (see signal_chrome.dart).
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [surface.cardHigh, surface.card],
          ),
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(18),
          ),
          border: Border(bottom: BorderSide(color: surface.line)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Both nav buttons disable for the duration of a pending
                    // push: functionally required for Signal (`showSignalPage`
                    // has no re-entrancy guard of its own — a rapid
                    // double-tap would double-push it), and applied to
                    // Settings too for UX consistency — `openLoopySettings`
                    // self-guards against a real double-push, but leaving
                    // its button tappable mid-push would still look live
                    // when it isn't.
                    _TrayButton(
                      key: const Key('settingsTray_settings'),
                      icon: Icons.settings_outlined,
                      label: l10n.settingsTooltip,
                      accent: surface.textSecondary,
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
                      // Signal-flow blue — the same hue that names "wet"
                      // routing on the Signal surface itself.
                      accent: surface.wetRoute,
                      onTap: isNavigating
                          ? null
                          : () => unawaited(
                              _navigate(
                                context,
                                () => showSignalPage(context),
                              ),
                            ),
                    ),
                    _TrayButton(
                      key: const Key('settingsTray_wifi'),
                      icon: Icons.wifi,
                      label: l10n.trayWifiLabel,
                      accent: surface.laneColor(7),
                      onTap: () => unawaited(
                        showComingSoonStub(
                          context,
                          feature: l10n.trayWifiLabel,
                        ),
                      ),
                    ),
                    _TrayButton(
                      key: const Key('settingsTray_bluetooth'),
                      icon: Icons.bluetooth,
                      label: l10n.trayBluetoothLabel,
                      accent: surface.laneColor(3),
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
                      accent: surface.laneColor(2),
                      onTap: () => unawaited(
                        showComingSoonStub(
                          context,
                          feature: l10n.trayTunerLabel,
                        ),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1, thickness: 1, color: surface.line),
                ),
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: surface.accent.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.brightness_6_outlined,
                        size: 16,
                        color: surface.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 3,
                          activeTrackColor: surface.accent,
                          inactiveTrackColor: surface.line,
                          thumbColor: surface.accent,
                          overlayColor: surface.accent.withValues(alpha: 0.12),
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                          ),
                        ),
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
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 34,
                      child: Text(
                        '${(brightness * 100).round()}%',
                        textAlign: TextAlign.end,
                        style: signalMono(color: surface.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
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

/// One tray shortcut: an icon in a coloured circular badge over a short
/// label, focusable and screen-reader operable via [FocusableTapTarget].
/// Null [onTap] renders dimmed and inert (used while a nav push from this
/// tray is in flight).
class _TrayButton extends StatelessWidget {
  const _TrayButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;

  /// The badge's tint — distinguishes each destination at a glance rather
  /// than five identical grey glyphs in a row (e.g. [SurfaceTheme.wetRoute]
  /// for Signal, a lane hue per stub).
  final Color accent;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final enabled = onTap != null;
    final tint = enabled ? accent : surface.textTertiary;
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: 14,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: enabled ? 0.16 : 0.08),
                shape: BoxShape.circle,
                border: Border.all(
                  color: tint.withValues(alpha: enabled ? 0.4 : 0.16),
                ),
              ),
              child: Icon(icon, color: tint, size: 20),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: signalLabel(
                color: enabled ? surface.textSecondary : surface.textTertiary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
