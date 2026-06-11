import 'package:flutter/material.dart';
import 'package:routing_graph/src/widgets/graph_card_ref.dart';
import 'package:routing_graph/src/widgets/graph_geometry.dart';

/// Builds the insertion drop zones in the gaps around a row's effect [cardXs].
///
/// One zone sits before each card (and one after the last); dropping a same-row
/// card on zone `pos` reports `(fromIndex, pos)` via [onMove], the single
/// gap-index reorder convention shared by every routing graph. When the chain
/// is empty a lone zone sits at [emptyStartX].
///
/// Keys derive from [keyPrefix] (`laneGraph` / `monitorGraph`) and [rowId];
/// [rowCenterY] vertically centres the zones; [accentColor] tints the caret.
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
