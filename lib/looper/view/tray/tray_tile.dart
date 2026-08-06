import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/theme/theme.dart';

/// One quick-access card on the tray's home face: icon, label, and an
/// optional status line.
///
/// The card **fills whatever box it is given** and derives its own icon and
/// text sizes from that box, so the home grid can hand it a cell and let it
/// scale — no pixel params cross this widget's API. Colour is a dual
/// state: [isOn] uses [SurfaceTheme.accent], otherwise the shared off colour
/// ([SurfaceTheme.textSecondary]). Destinations that cannot be "on" pass
/// `isOn: false`. Null [onTap] dims the card (nav-in-flight / unsupported
/// radio); [onLongPress] still opens config when set.
class TrayTile extends StatelessWidget {
  /// Creates a [TrayTile].
  const TrayTile({
    required this.icon,
    required this.label,
    required this.isOn,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
    this.semanticLabel,
    super.key,
  });

  /// Glyph shown above the label.
  final IconData icon;

  /// Primary caption.
  final String label;

  /// Optional status line under the label — the SSID, the paired device, or
  /// an off state. Before this card filled the pane there was no room for it,
  /// and the radios had to fold their status into [label] instead.
  final String? subtitle;

  /// Dual-state tint: accent when on, shared off colour when off.
  final bool isOn;

  /// Null renders the card dimmed — nav push in flight, or unsupported radio.
  final VoidCallback? onTap;

  /// Long-press opens in-tray config (WiFi / Bluetooth).
  final VoidCallback? onLongPress;

  /// Accessibility label; defaults to [label] when null.
  final String? semanticLabel;

  /// Corner radius, as a fraction of the card's shorter side — a fixed radius
  /// reads as a different shape at every card size.
  static const double _radiusFraction = 0.14;
  static const double _maxRadius = 28;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final accent = isOn ? surface.accent : surface.textSecondary;
    // Tappable when either gesture is available (long-press alone still works
    // for unsupported radios that can open the config face).
    final interactive = onTap != null || onLongPress != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final shortSide = math.min(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        final radius = math.min(shortSide * _radiusFraction, _maxRadius);
        // Everything scales off the card's shorter side, clamped so a very
        // large pane does not produce a comically oversized glyph and a very
        // small one stays legible.
        final iconSize = (shortSide * 0.3).clamp(22.0, 120.0);
        final labelSize = (shortSide * 0.1).clamp(11.0, 30.0);

        return FocusableTapTarget(
          onTap: onTap,
          onLongPress: onLongPress,
          semanticLabel: semanticLabel ?? label,
          selected: isOn,
          borderRadius: radius,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: interactive ? 1 : 0.4,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: EdgeInsets.all(shortSide * 0.1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                color: accent.withValues(alpha: isOn ? 0.22 : 0.08),
                border: Border.all(
                  color: accent.withValues(alpha: isOn ? 0.45 : 0.16),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: accent, size: iconSize),
                  SizedBox(height: shortSide * 0.06),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontSize: labelSize,
                      height: 1.1,
                      leadingDistribution: TextLeadingDistribution.even,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle case final subtitle?) ...[
                    SizedBox(height: shortSide * 0.02),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textTertiary,
                        fontSize: labelSize * 0.78,
                        height: 1.1,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
