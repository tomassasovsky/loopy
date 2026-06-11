import 'package:flutter/material.dart';
import 'package:loopy/theme/surface_theme.dart';

/// One hardware input/output port chip in a routing graph.
///
/// Purely presentational and fully caller-driven: [color] is resolved by the
/// caller (each graph colours its ports by its own rule), and the meaning of a
/// tap is the caller's [onTap]. The chip sizes itself to its parent (callers
/// wrap it in a [Positioned]).
class ChannelChip extends StatelessWidget {
  /// Creates a port chip.
  const ChannelChip({
    required this.label,
    required this.color,
    required this.strong,
    required this.wired,
    required this.excluded,
    required this.onTap,
    super.key,
  });

  /// The port label, e.g. `In 1` / `Out 2`.
  final String label;

  /// The caller-resolved accent for this port when it is wired/strong.
  final Color color;

  /// Emphasised: the focused row uses this port (brighter fill + border).
  final bool strong;

  /// Some row uses this port (coloured border + bright text).
  final bool wired;

  /// A loopback port that can never be wired (struck-through, dimmed).
  final bool excluded;

  /// What a tap means, or null when the port is not tappable.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final border = excluded
        ? surface.line
        : strong
        ? color
        : wired
        ? color.withValues(alpha: 0.7)
        : surface.line.withValues(alpha: 0.6);
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: !excluded && strong
                ? color.withValues(alpha: 0.28)
                : surface.card,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: border, width: strong ? 1.6 : 1),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: excluded
                  ? surface.textTertiary
                  : wired
                  ? surface.textPrimary
                  : surface.textTertiary,
              decoration: excluded ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
    );
  }
}
