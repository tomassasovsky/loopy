import 'package:flutter/material.dart';
import 'package:routing_graph/src/theme/routing_graph_theme.dart';
import 'package:routing_graph/src/widgets/focusable_tap_target.dart';

/// One hardware input/output port chip in a routing graph.
///
/// Purely presentational and fully caller-driven: [color] is resolved by the
/// caller (each graph colours its ports by its own rule), and the meaning of a
/// tap is the caller's [onTap]. The chip sizes itself to its parent (callers
/// wrap it in a [Positioned]).
///
/// It is keyboard-focusable and screen-reader-labelled (via
/// [FocusableTapTarget]): callers may pass a localized [semanticLabel];
/// otherwise the visible [label] plus the wired/excluded state form the
/// accessible name.
class ChannelChip extends StatelessWidget {
  /// Creates a port chip.
  const ChannelChip({
    required this.label,
    required this.color,
    required this.strong,
    required this.wired,
    required this.excluded,
    required this.onTap,
    this.semanticLabel,
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

  /// Optional localized accessible name. When null, a default is derived from
  /// [label] and the wired/excluded state so the chip is never unlabelled.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = context.routingGraph;
    final border = excluded
        ? theme.line
        : strong
        ? color
        : wired
        ? color.withValues(alpha: 0.7)
        : theme.line.withValues(alpha: 0.6);
    final state = excluded
        ? 'loopback, unavailable'
        : wired
        ? 'routed'
        : 'not routed';
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: semanticLabel ?? '$label, $state',
      selected: !excluded && (wired || strong),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: !excluded && strong
              ? color.withValues(alpha: 0.28)
              : theme.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: strong ? 1.6 : 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: excluded
                ? theme.textTertiary
                : wired
                ? theme.textPrimary
                : theme.textTertiary,
            decoration: excluded ? TextDecoration.lineThrough : null,
          ),
        ),
      ),
    );
  }
}
