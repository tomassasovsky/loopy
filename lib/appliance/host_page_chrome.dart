import 'dart:async';

import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';

/// Compact page chrome for appliance host surfaces (WiFi / Bluetooth):
/// Close + title on the left, optional action on the right.
class HostChromeBar extends StatelessWidget {
  /// Creates a [HostChromeBar].
  const HostChromeBar({
    required this.backKey,
    required this.title,
    this.trailing,
    super.key,
  });

  /// Key for the close/back control.
  final Key backKey;

  /// Page title.
  final String title;

  /// Optional trailing control (e.g. scan).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
      child: Row(
        children: [
          TextButton.icon(
            key: backKey,
            onPressed: () => unawaited(Navigator.of(context).maybePop()),
            icon: const Icon(Icons.chevron_left, size: 18),
            label: Text(l10n.close),
            style: TextButton.styleFrom(
              foregroundColor: surface.textSecondary,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            title,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// In-tray chrome: back affordance + title (+ optional trailing), sized so
/// the title shares a vertical center with the chevron (no IconButton
/// padding skew).
class HostTrayChromeBar extends StatelessWidget {
  /// Creates a [HostTrayChromeBar].
  const HostTrayChromeBar({
    required this.backKey,
    required this.title,
    required this.onBack,
    this.trailing,
    super.key,
  });

  /// Key for the back control.
  final Key backKey;

  /// Division title.
  final String title;

  /// Returns to the tray home (does not dismiss the tray).
  final VoidCallback onBack;

  /// Optional trailing control (e.g. scan).
  final Widget? trailing;

  /// Compact enough that a no-descender title ("Bluetooth") doesn't sit
  /// above a hollow band that reads as bottom padding.
  static const double _height = 32;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final backLabel = context.l10n.trayBackLabel;

    return SizedBox(
      height: _height,
      child: Row(
        children: [
          Tooltip(
            message: backLabel,
            child: Semantics(
              button: true,
              label: backLabel,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: backKey,
                  onTap: onBack,
                  customBorder: const CircleBorder(),
                  child: SizedBox(
                    width: _height,
                    height: _height,
                    child: Center(
                      child: Icon(
                        Icons.chevron_left,
                        size: 22,
                        color: surface.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Caps-only titles (WiFi / Bluetooth) paint slightly high of the
          // Material icon optical center; 1px nudge matches chevron/refresh.
          Transform.translate(
            offset: const Offset(0, 1),
            child: Text(
              title,
              strutStyle: const StrutStyle(
                fontSize: 16,
                height: 1,
                leading: 0,
                forceStrutHeight: true,
              ),
              textHeightBehavior: const TextHeightBehavior(
                applyHeightToFirstAscent: false,
                applyHeightToLastDescent: false,
              ),
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
          const Spacer(),
          if (trailing != null)
            SizedBox(
              height: _height,
              width: _height,
              child: Center(child: trailing),
            ),
        ],
      ),
    );
  }
}

/// Compact icon button for the chrome trailing slot.
class HostChromeIconButton extends StatelessWidget {
  /// Creates a [HostChromeIconButton].
  const HostChromeIconButton({
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.spinner = false,
    super.key,
  });

  /// Icon when not spinning.
  final IconData? icon;

  /// Tooltip / a11y name.
  final String tooltip;

  /// Null disables the button.
  final VoidCallback? onPressed;

  /// Replaces [icon] with a small spinner.
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      icon: spinner
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
    );
  }
}

/// Dense action chip used in status panes (Disconnect / Forget).
class HostActionChip extends StatelessWidget {
  /// Creates a [HostActionChip].
  const HostActionChip({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  /// Chip label.
  final String label;

  /// Leading icon.
  final IconData icon;

  /// Null dims and disables the chip.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: surface.background.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: onPressed == null
                    ? surface.textTertiary
                    : surface.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: onPressed == null
                      ? surface.textTertiary
                      : surface.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
