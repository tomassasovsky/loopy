import 'package:flutter/material.dart';
import 'package:loopy/setup/setup_surface.dart';

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
class EffectChainCard extends StatelessWidget {
  /// Creates an effect card.
  const EffectChainCard({
    required this.cardKey,
    required this.handleKey,
    required this.labelKey,
    required this.deleteKey,
    required this.label,
    required this.accentColor,
    required this.selected,
    required this.dragging,
    required this.rowId,
    required this.index,
    required this.cardW,
    required this.cardH,
    required this.onTap,
    required this.onDelete,
    required this.onDragStart,
    required this.onDragEnd,
    super.key,
  });

  /// Keys for the card body and its interactive parts (caller-supplied so each
  /// graph keeps its own selector names).
  final Key cardKey;
  final Key handleKey;
  final Key labelKey;
  final Key deleteKey;

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

  /// The card's size, also used for the drag feedback.
  final double cardW;
  final double cardH;

  /// Edit (tap the label), delete, and drag lifecycle callbacks.
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  BoxDecoration get _decoration => BoxDecoration(
    color: SetupSurfaceColors.cardHi.withValues(alpha: dragging ? 0.4 : 1),
    borderRadius: BorderRadius.circular(8),
    border: Border.all(
      color: selected ? accentColor : accentColor.withValues(alpha: 0.45),
      width: selected ? 2 : 1,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final handle = Draggable<GraphCardRef>(
      key: handleKey,
      data: GraphCardRef(rowId, index),
      onDragStarted: onDragStart,
      onDragEnd: (_) => onDragEnd(),
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: cardW,
          height: cardH,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: SetupSurfaceColors.cardHi,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accentColor),
            ),
            child: Center(
              child: Text(
                label,
                style: const TextStyle(color: SetupSurfaceColors.t1),
              ),
            ),
          ),
        ),
      ),
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Icon(
          Icons.drag_indicator,
          size: 16,
          color: SetupSurfaceColors.t3,
        ),
      ),
    );
    return Container(
      key: cardKey,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: _decoration,
      child: Row(
        children: [
          handle,
          const SizedBox(width: 4),
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: labelKey,
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: SetupSurfaceColors.t1),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: 'Remove effect',
            child: InkResponse(
              key: deleteKey,
              onTap: onDelete,
              radius: 16,
              child: const SizedBox(
                width: 20,
                height: 24,
                child: Icon(
                  Icons.close,
                  size: 15,
                  color: SetupSurfaceColors.t2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A drop target in the gap before a card (or after the last one). Accepts only
/// cards from the same [rowId] and reports the dragged card's original index to
/// [onAccept]; the caller knows which gap this zone is and moves accordingly. A
/// caret shows where the card will land.
class EffectDropZone extends StatelessWidget {
  /// Creates a drop zone.
  const EffectDropZone({
    required this.dropKey,
    required this.rowId,
    required this.accentColor,
    required this.caretHeight,
    required this.onAccept,
    super.key,
  });

  /// The zone's key (caller-supplied).
  final Key dropKey;

  /// Only cards from this row are accepted.
  final int rowId;

  /// The insertion-caret colour.
  final Color accentColor;

  /// The caret's height (the card height).
  final double caretHeight;

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
                  height: caretHeight,
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
    this.iconSize = 24,
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

  /// The add-icon size; the opaque backdrop is sized to its ring.
  final double iconSize;

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
              width: iconSize - 5,
              height: iconSize - 5,
              decoration: const BoxDecoration(
                color: SetupSurfaceColors.surface,
                shape: BoxShape.circle,
              ),
            ),
            IconButton(
              key: buttonKey,
              iconSize: iconSize,
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
