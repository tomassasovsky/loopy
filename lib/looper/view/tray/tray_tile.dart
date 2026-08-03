import 'package:flutter/material.dart';
import 'package:loopy/theme/theme.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

/// One Control Center tile: round glass button + caption. Color is a dual
/// state — [isOn] uses [SurfaceTheme.accent], otherwise the shared off color
/// ([SurfaceTheme.textSecondary]). Destinations that cannot be "on" pass
/// `isOn: false`. Null [onTap] dims the tile (nav-in-flight / unsupported
/// radio); [onLongPress] still opens config when set.
class TrayTile extends StatelessWidget {
  /// Creates a [TrayTile].
  const TrayTile({
    required this.icon,
    required this.label,
    required this.isOn,
    required this.onTap,
    this.onLongPress,
    this.semanticLabel,
    super.key,
  });

  /// Glyph shown in the circle.
  final IconData icon;

  /// Caption under the circle.
  final String label;

  /// Dual-state tint: accent when on, shared off color when off.
  final bool isOn;

  /// Null renders the tile dimmed — nav push in flight, or unsupported radio.
  final VoidCallback? onTap;

  /// Long-press opens in-tray config (WiFi / Bluetooth).
  final VoidCallback? onLongPress;

  /// Accessibility label; defaults to [label] when null.
  final String? semanticLabel;

  /// Circle diameter — independent of the tile's overall footprint (which
  /// also has to fit the caption below), same as before the caption existed.
  static const _circleSize = 72.0;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final accent = isOn ? surface.accent : surface.textSecondary;
    // Tappable when either gesture is available (long-press alone still works
    // for unsupported radios that can open the config face).
    final interactive = onTap != null || onLongPress != null;
    return FocusableTapTarget(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: semanticLabel ?? label,
      selected: isOn,
      borderRadius: _circleSize / 2,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: interactive ? 1 : 0.4,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _circleSize,
              height: _circleSize,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: isOn ? 0.28 : 0.14),
                ),
                child: Center(child: Icon(icon, color: accent, size: 26)),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
