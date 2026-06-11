import 'package:flutter/material.dart';
import 'package:routing_graph/src/theme/routing_graph_theme.dart';
import 'package:routing_graph/src/widgets/graph_card_ref.dart';
import 'package:routing_graph/src/widgets/graph_geometry.dart';

/// One effect card on a row's chain: a drag handle (reorder), a tappable label
/// (edit), and a delete button. The card is the drag *source*; the gaps between
/// cards (an `EffectDropZone`) are the drop targets, so reordering uses one
/// insertion-index convention across every graph.
///
/// Keys are derived from a single [keyPrefix] (e.g. `laneGraph` / `monitorGraph`)
/// so each graph keeps its own selector namespace without threading four keys.
class EffectChainCard extends StatelessWidget {
  /// Creates an effect card.
  const EffectChainCard({
    required this.keyPrefix,
    required this.label,
    required this.accentColor,
    required this.selected,
    required this.dragging,
    required this.rowId,
    required this.index,
    required this.onTap,
    required this.onDelete,
    required this.onDragStart,
    required this.onDragEnd,
    super.key,
  });

  /// The graph's selector namespace, e.g. `laneGraph` or `monitorGraph`.
  final String keyPrefix;

  /// The effect's display label.
  final String label;

  /// The row's accent (lane hue or send role colour).
  final Color accentColor;

  /// Whether this card is the selected (open-in-the-editor) one.
  final bool selected;

  /// Whether this card is the one currently being dragged (drawn dimmed).
  final bool dragging;

  /// Identifies the card's row for the drag payload + same-row drop guard.
  final int rowId;

  /// The card's position in its row's chain.
  final int index;

  /// Called when the label is tapped (open the card in the editor).
  final VoidCallback onTap;

  /// Called when the delete button is tapped.
  final VoidCallback onDelete;

  /// Called when a drag of this card begins.
  final VoidCallback onDragStart;

  /// Called when a drag of this card ends.
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final theme = context.routingGraph;
    final decoration = BoxDecoration(
      color: theme.cardHigh.withValues(alpha: dragging ? 0.4 : 1),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color: selected ? accentColor : accentColor.withValues(alpha: 0.45),
        width: selected ? 2 : 1,
      ),
    );
    final handle = Draggable<GraphCardRef>(
      key: Key('${keyPrefix}_fxHandle_${rowId}_$index'),
      data: GraphCardRef(rowId, index),
      onDragStarted: onDragStart,
      onDragEnd: (_) => onDragEnd(),
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: kRoutingCardWidth,
          height: kRoutingCardHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.cardHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accentColor),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(color: theme.textPrimary),
              ),
            ),
          ),
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Icon(
          Icons.drag_indicator,
          size: 16,
          color: theme.textTertiary,
        ),
      ),
    );
    return Container(
      key: Key('${keyPrefix}_fx_${rowId}_$index'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: decoration,
      child: Row(
        children: [
          handle,
          const SizedBox(width: 4),
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: Key('${keyPrefix}_fxLabel_${rowId}_$index'),
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.textPrimary),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: 'Remove effect',
            child: InkResponse(
              key: Key('${keyPrefix}_fxDelete_${rowId}_$index'),
              onTap: onDelete,
              radius: 16,
              child: SizedBox(
                width: 20,
                height: 24,
                child: Icon(
                  Icons.close,
                  size: 15,
                  color: theme.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
