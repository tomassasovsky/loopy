import 'package:flutter/material.dart';
import 'package:loopy/common/routing_graph/graph_geometry.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The drag payload when reordering an effect: a reference to one card by its
/// [rowId] (lane index or monitored input) and its [index] in that row's chain.
///
/// Drop targets check [rowId] so a card can only be dropped back onto its own
/// row — a card never jumps rows.
@immutable
class GraphCardRef {
  /// Creates a card reference.
  const GraphCardRef(this.rowId, this.index);

  /// The row the card belongs to (lane index / monitored input).
  final int rowId;

  /// The card's position in its row's chain.
  final int index;
}

/// One effect card on a row's chain: a drag handle (reorder), a tappable label
/// (edit), and a delete button. The card is the drag *source*; the gaps between
/// cards ([EffectDropZone]) are the drop targets, so reordering uses one
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

  /// Identifies the card for the drag payload + same-row drop guard.
  final int rowId;
  final int index;

  /// Edit (tap the label), delete, and drag lifecycle callbacks.
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final decoration = BoxDecoration(
      color: surface.cardHigh.withValues(alpha: dragging ? 0.4 : 1),
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
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accentColor),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(color: surface.textPrimary),
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
          color: surface.textTertiary,
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
                  style: TextStyle(color: surface.textPrimary),
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
                  color: surface.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Builds the insertion drop zones in the gaps around a row's effect [cardXs].
///
/// One zone sits before each card (and one after the last); dropping a same-row
/// card on zone `pos` reports `(fromIndex, pos)` via [onMove], the single
/// gap-index reorder convention shared by every routing graph. When the chain
/// is empty a lone zone sits at [emptyStartX].
List<Widget> buildEffectDropZones({
  required String keyPrefix,
  required int rowId,
  required List<double> cardXs,
  required double emptyStartX,
  required double rowCenterY,
  required Color accentColor,
  required void Function(int fromIndex, int gapIndex) onMove,
}) {
  final spots = <double>[];
  if (cardXs.isEmpty) {
    spots.add(emptyStartX);
  } else {
    for (final x in cardXs) {
      spots.add(x - kRoutingCardGap);
    }
    spots.add(cardXs.last + kRoutingCardWidth);
  }
  return [
    for (var pos = 0; pos < spots.length; pos++)
      Positioned(
        left: spots[pos],
        top: rowCenterY - kRoutingCardHeight / 2 - 6,
        width: kRoutingCardGap + 10,
        height: kRoutingCardHeight + 12,
        child: EffectDropZone(
          dropKey: Key('${keyPrefix}_drop_${rowId}_$pos'),
          rowId: rowId,
          accentColor: accentColor,
          onAccept: (from) => onMove(from, pos),
        ),
      ),
  ];
}

/// A drop target in the gap before a card (or after the last one). Accepts only
/// cards from the same [rowId] and reports the dragged card's original index to
/// [onAccept]; a caret shows where the card will land.
class EffectDropZone extends StatelessWidget {
  /// Creates a drop zone.
  const EffectDropZone({
    required this.dropKey,
    required this.rowId,
    required this.accentColor,
    required this.onAccept,
    super.key,
  });

  /// The zone's key (caller-supplied).
  final Key dropKey;

  /// Only cards from this row are accepted.
  final int rowId;

  /// The insertion-caret colour.
  final Color accentColor;

  /// Called with the dragged card's original index when a same-row card drops.
  final void Function(int fromIndex) onAccept;

  @override
  Widget build(BuildContext context) {
    return DragTarget<GraphCardRef>(
      onWillAcceptWithDetails: (d) => d.data.rowId == rowId,
      onAcceptWithDetails: (d) => onAccept(d.data.index),
      builder: (_, candidate, _) => SizedBox.expand(
        key: dropKey,
        child: candidate.isEmpty
            ? null
            : Center(
                child: Container(
                  width: 3,
                  height: kRoutingCardHeight,
                  color: accentColor,
                ),
              ),
      ),
    );
  }
}

/// The "add an effect" button at the end of a chain. Keeps an opaque disc
/// behind the icon so the routing wire passing through is masked, not visible
/// through the button's hole.
class AddEffectButton extends StatelessWidget {
  /// Creates an add-effect button.
  const AddEffectButton({
    required this.buttonKey,
    required this.accentColor,
    required this.full,
    required this.onAdd,
    required this.tooltip,
    super.key,
  });

  /// The button's key (caller-supplied).
  final Key buttonKey;

  /// The row's accent colour.
  final Color accentColor;

  /// Whether the chain is full (button disabled).
  final bool full;

  /// Adds an effect to the row.
  final VoidCallback onAdd;

  /// The enabled-state tooltip (the disabled tooltip is "Chain is full").
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Opaque disc sized to the icon's ring, so the routing wire is
            // masked behind the button without any fill showing past it.
            Container(
              width: 19,
              height: 19,
              decoration: BoxDecoration(
                color: context.surface.surface,
                shape: BoxShape.circle,
              ),
            ),
            IconButton(
              key: buttonKey,
              iconSize: 24,
              padding: EdgeInsets.zero,
              color: accentColor,
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              style: IconButton.styleFrom(
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              tooltip: full ? 'Chain is full' : tooltip,
              icon: const Icon(Icons.add_circle_outline),
              onPressed: full ? null : onAdd,
            ),
          ],
        ),
      ),
    );
  }
}
