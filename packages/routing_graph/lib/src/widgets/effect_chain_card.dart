import 'package:flutter/material.dart';
import 'package:routing_graph/src/theme/routing_graph_theme.dart';
import 'package:routing_graph/src/widgets/focusable_tap_target.dart';
import 'package:routing_graph/src/widgets/graph_card_ref.dart';
import 'package:routing_graph/src/widgets/graph_geometry.dart';

/// One effect card on a row's chain: a drag handle (reorder), a tappable label
/// (edit), and a delete button. The card is the drag *source*; the gaps between
/// cards (an `EffectDropZone`) are the drop targets, so reordering uses one
/// insertion-index convention across every graph.
///
/// Reordering by drag has a keyboard/single-pointer alternative (WCAG 2.5.7):
/// when [onMoveLeft]/[onMoveRight] are provided, focusable move buttons appear
/// on the card. The label and delete affordances are keyboard-operable and
/// screen-reader-labelled via [FocusableTapTarget].
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
    this.onMoveLeft,
    this.onMoveRight,
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

  /// Non-drag reorder: move this card one slot earlier. Null hides the button
  /// (e.g. the first card cannot move left).
  final VoidCallback? onMoveLeft;

  /// Non-drag reorder: move this card one slot later. Null hides the button
  /// (e.g. the last card cannot move right).
  final VoidCallback? onMoveRight;

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
            child: FocusableTapTarget(
              key: Key('${keyPrefix}_fxLabel_${rowId}_$index'),
              onTap: onTap,
              selected: selected,
              semanticLabel: 'Effect $label, position ${index + 1}, edit',
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.textPrimary),
              ),
            ),
          ),
          if (onMoveLeft != null || onMoveRight != null) ...[
            const SizedBox(width: 2),
            _CardIconButton(
              buttonKey: Key('${keyPrefix}_fxMoveLeft_${rowId}_$index'),
              icon: Icons.chevron_left,
              tooltip: 'Move effect left',
              color: theme.textSecondary,
              onTap: onMoveLeft,
            ),
            _CardIconButton(
              buttonKey: Key('${keyPrefix}_fxMoveRight_${rowId}_$index'),
              icon: Icons.chevron_right,
              tooltip: 'Move effect right',
              color: theme.textSecondary,
              onTap: onMoveRight,
            ),
          ],
          const SizedBox(width: 2),
          _CardIconButton(
            buttonKey: Key('${keyPrefix}_fxDelete_${rowId}_$index'),
            icon: Icons.close,
            tooltip: 'Remove effect',
            color: theme.textSecondary,
            onTap: onDelete,
          ),
        ],
      ),
    );
  }
}

/// A compact, keyboard-accessible icon button for an effect card's controls
/// (move / delete). Meets the 24x24 dp minimum target size (WCAG 2.5.8) and is
/// focusable + labelled without needing a Material ancestor on the canvas.
class _CardIconButton extends StatelessWidget {
  const _CardIconButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Tooltip(
      message: tooltip,
      child: FocusableTapTarget(
        key: buttonKey,
        onTap: onTap,
        semanticLabel: tooltip,
        child: SizedBox(
          width: 24,
          height: 24,
          child: Icon(
            icon,
            size: 16,
            color: disabled ? color.withValues(alpha: 0.4) : color,
          ),
        ),
      ),
    );
  }
}
