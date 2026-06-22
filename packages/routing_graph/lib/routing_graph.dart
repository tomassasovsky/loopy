/// Reusable routing-graph UI primitives.
///
/// A zoom/pan `GraphCanvas`, bezier wires (`GraphEdge` + `GraphEdgePainter`),
/// hardware-port `ChannelChip`s, draggable `EffectChainCard`s with their
/// `EffectDropZone`s and `AddEffectButton`, and the geometry helpers
/// (`cardColumnXs`, `chainEdges`, `fanEdges`, `positionedNode`) that lay them
/// out. Neutral structural colours come from `RoutingGraphTheme` (read via
/// `context.routingGraph`); caller-specific semantic colours stay constructor
/// parameters.
library;

export 'package:flutter/material.dart';

export 'src/theme/routing_graph_theme.dart';
export 'src/widgets/add_effect_button.dart';
export 'src/widgets/channel_chip.dart';
export 'src/widgets/effect_chain_card.dart';
export 'src/widgets/effect_drop_zone.dart';
export 'src/widgets/focusable_tap_target.dart';
export 'src/widgets/graph_canvas.dart';
export 'src/widgets/graph_card_ref.dart';
export 'src/widgets/graph_edge.dart';
export 'src/widgets/graph_edge_painter.dart';
export 'src/widgets/graph_geometry.dart';
