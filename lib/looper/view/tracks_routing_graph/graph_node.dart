import 'package:loopy/looper/view/tracks_routing_graph/routing_graph.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// A single routing-graph node rendered as an interactive widget so it can show
/// hover/armed/target states and a connect/disconnect affordance.
class RoutingGraphNode extends StatelessWidget {
  /// Creates a [RoutingGraphNode].
  const RoutingGraphNode({
    required this.node,
    required this.interactive,
    required this.armed,
    required this.isTarget,
    required this.connected,
    required this.hovered,
    required this.onTap,
    required this.onHover,
    super.key,
  });

  /// The node this widget renders.
  final RoutingNode node;

  /// Whether the graph is editable (so the node reacts to taps/hover).
  final bool interactive;

  /// Whether this is the armed track node.
  final bool armed;

  /// Whether this channel is a connectable target for the armed track.
  final bool isTarget;

  /// Whether a target channel is already wired to the armed track (null when
  /// not a target).
  final bool? connected;

  /// Whether the pointer is over this node.
  final bool hovered;

  /// Tapped, or null when the node is not interactive.
  final VoidCallback? onTap;

  /// Pointer enter/exit (passes this node, or null on exit).
  final ValueChanged<RoutingNode?>? onHover;

  @override
  Widget build(BuildContext context) {
    final isTrack = node.kind == RoutingNodeKind.track;

    Color fill;
    Color border;
    var borderWidth = 1.0;
    var textColor = context.surface.textPrimary;

    if (node.excluded) {
      fill = context.surface.cardHigh;
      border = context.surface.line;
      textColor = context.surface.textTertiary;
    } else if (isTrack) {
      fill = context.surface.accent.withValues(alpha: armed ? 0.34 : 0.18);
      border = armed
          ? context.surface.accent
          : context.surface.accent.withValues(alpha: 0.6);
      borderWidth = armed ? 2 : 1;
    } else if (isTarget) {
      // A channel that can be wired to the armed track.
      fill = connected ?? false
          ? context.surface.accent.withValues(alpha: 0.30)
          : context.surface.card;
      border = connected ?? false
          ? context.surface.accent
          : context.surface.accent.withValues(alpha: 0.7);
    } else {
      fill = context.surface.card;
      border = context.surface.line;
      textColor = context.surface.textSecondary;
    }
    if (hovered) {
      border = Color.alphaBlend(Colors.white.withValues(alpha: 0.18), border);
    }

    // On a target while armed, hint the action: + to connect, ✕ to remove.
    final hint = isTarget && hovered
        ? (connected ?? false ? Icons.close : Icons.add)
        : null;

    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: borderWidth),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              node.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: isTrack ? FontWeight.w600 : FontWeight.w500,
                decoration: node.excluded ? TextDecoration.lineThrough : null,
                decorationColor: context.surface.textTertiary,
              ),
            ),
          ),
          if (hint != null)
            Positioned(
              right: 5,
              child: Icon(hint, size: 13, color: textColor),
            ),
        ],
      ),
    );

    if (!interactive || onTap == null) return content;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover?.call(node),
      onExit: (_) => onHover?.call(null),
      child: GestureDetector(
        key: Key('routingNode_${node.kind.name}_${node.index}'),
        onTap: onTap,
        child: content,
      ),
    );
  }
}
