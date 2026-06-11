import 'package:flutter/material.dart';

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
