import 'dart:math' as math;

import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:routing_graph/routing_graph.dart';

/// Pure geometry for one frame of the monitor graph: node positions, card
/// positions, and the wires. Computed once per build from the monitor state, so
/// the build method composes widgets instead of threading a dozen coordinates
/// around.
///
/// Each monitored input has two parallel sends: the **effected (wet)** signal
/// runs through the chain to its outputs, and the **clean (dry)** signal leaves
/// from the bottom centre of the monitor node to its own outputs.
@immutable
class MonitorGraphLayout {
  const MonitorGraphLayout._({
    required this.rows,
    required this.cardXs,
    required this.edges,
    required this.wetUnion,
    required this.dryUnion,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.inX,
    required this.nodeX,
    required this.outX,
    required this.excludedMask,
    required int inCount,
    required int outCount,
    required Map<int, double> rowCenterY,
  }) : _inCount = inCount,
       _outCount = outCount,
       _rowCenterY = rowCenterY;

  factory MonitorGraphLayout.compute({
    required MonitorState state,
    required int inCount,
    required int outCount,
    required int excludedMask,
    required int? focused,
    required Color wetColor,
    required Color dryColor,
  }) {
    bool isExcluded(int c) => excludedMask & (1 << c) != 0;
    final rows = [
      for (var c = 0; c < inCount; c++)
        if (state.forInput(c).enabled && !isExcluded(c)) c,
    ];

    const inX = padding;
    const nodeX = inX + channelChipWidth + fanGutter;

    final cardXs = <int, List<double>>{};
    var widestRight = cardStartX;
    for (final c in rows) {
      final xs = cardColumnXs(
        startX: cardStartX,
        count: state.forInput(c).effects.length,
        cardW: cardWidth,
        gap: cardGap,
      );
      cardXs[c] = xs;
      final rowRight =
          (xs.isEmpty ? cardStartX : xs.last + cardWidth + cardGap) +
          addSlotWidth;
      widestRight = math.max(widestRight, rowRight);
    }
    final railX = widestRight;
    final outX = railX + fanGutter;
    final canvasWidth = outX + channelChipWidth + padding;

    final rowsBlockHeight = rows.length * monitorRowHeight;
    final channelsHeight = math.max(inCount, outCount) * channelRowHeight;
    final canvasHeight =
        math.max(rowsBlockHeight, channelsHeight) + padding * 2;
    final rowsTop = (canvasHeight - rowsBlockHeight) / 2;

    double chYAt(int i, int count) => canvasHeight / count * (i + 0.5);
    double rowYAt(int r) =>
        rowsTop + r * monitorRowHeight + monitorRowHeight / 2;
    final rowCenterY = {
      for (var r = 0; r < rows.length; r++) rows[r]: rowYAt(r),
    };

    var wetUnion = 0;
    var dryUnion = 0;
    final edges = <GraphEdge>[];
    for (var r = 0; r < rows.length; r++) {
      final c = rows[r];
      final m = state.forInput(c);
      final y = rowYAt(r);
      final faded = focused != null && focused != c;
      wetUnion |= m.enabled ? m.outputMask : 0;
      dryUnion |= m.enabled ? m.dryOutputMask : 0;

      // input feed → monitor node
      if (!isExcluded(c)) {
        edges.add(
          GraphEdge(
            Offset(inX + channelChipWidth, chYAt(c, inCount)),
            Offset(nodeX, y),
            color: wetColor,
            faded: faded,
          ),
        );
      }
      // wet path: node → cards → last
      final xs = cardXs[c]!;
      edges.addAll(
        chainEdges(
          nodeRight: nodeX + monitorNodeWidth,
          y: y,
          cardXs: xs,
          cardW: cardWidth,
          color: wetColor,
          faded: faded,
        ),
      );
      final rightX = xs.isEmpty
          ? nodeX + monitorNodeWidth
          : xs.last + cardWidth;
      const dryX = nodeX + monitorNodeWidth / 2;
      final dryCardBottom = y + monitorNodeHeight / 2;
      final dryY = y + dryDrop;
      // The dry send drops below the node, then turns to run across. End the
      // drop a knee-radius past the corner so the painter can round the 90°
      // turn; the fan then continues the horizontal from that point.
      const dryAcrossX = dryX + dryCornerRadius;
      if (m.dryOutputMask != 0) {
        edges.add(
          GraphEdge(
            Offset(dryX, dryCardBottom),
            Offset(dryAcrossX, dryY),
            color: dryColor,
            knee: Offset(dryX, dryY),
            faded: faded,
            dashed: true,
          ),
        );
      }
      // Two parallel sends: wet from the chain tail, dry from below the
      // monitor node (90° down then across), each fanned to its own outputs.
      edges.addAll(
        fanEdges(
          sends: [
            GraphSend(
              originX: rightX,
              originY: y,
              mask: m.outputMask,
              color: wetColor,
            ),
            GraphSend(
              originX: dryAcrossX,
              originY: dryY,
              mask: m.dryOutputMask,
              color: dryColor,
              dashed: true,
            ),
          ],
          railX: railX,
          outX: outX,
          outCount: outCount,
          outY: chYAt,
          faded: faded,
        ),
      );
    }

    return MonitorGraphLayout._(
      rows: rows,
      cardXs: cardXs,
      edges: edges,
      wetUnion: wetUnion,
      dryUnion: dryUnion,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      inX: inX,
      nodeX: nodeX,
      outX: outX,
      excludedMask: excludedMask,
      inCount: inCount,
      outCount: outCount,
      rowCenterY: rowCenterY,
    );
  }

  // Geometry constants. Inputs/outputs are small "channel" chips; a monitored
  // input is a wider node feeding a horizontal chain of effect cards. The card
  // footprint comes from the shared kit metrics (kRoutingCard*).
  static const double channelChipWidth = 54;
  static const double channelChipHeight = 24;
  static const double channelRowHeight = 32; // vertical pitch between chips
  static const double monitorNodeWidth = 128;
  static const double monitorNodeHeight = 50;
  static const double monitorRowHeight = 80; // vertical pitch between rows
  static const double cardWidth = kRoutingCardWidth;
  static const double cardGap = kRoutingCardGap;
  static const double fanGutter = 150; // input→node / rail→output gutter
  static const double addSlotWidth = kRoutingAddSlot; // add-effect button slot
  static const double padding = 16; // canvas padding
  // The dry edge leaves below the node so it clears the cards.
  static const double dryDrop = kRoutingCardHeight / 2 + 15;
  // Radius of the dry send's rounded drop→across corner. Kept under the drop
  // height so the painter's clamp leaves a little straight run before the turn.
  static const double dryCornerRadius = 6;

  /// The x of the first effect card (also the empty-chain drop spot).
  static const double cardStartX =
      padding + channelChipWidth + fanGutter + monitorNodeWidth + cardGap;

  /// Monitored input indices, in input order (one middle row each).
  final List<int> rows;

  /// Per monitored input: the x of each effect card.
  final Map<int, List<double>> cardXs;

  /// The wires to paint.
  final List<GraphEdge> edges;

  /// Outputs reached by any monitor's wet / dry send (for node colouring).
  final int wetUnion;
  final int dryUnion;

  final double canvasWidth;
  final double canvasHeight;
  final double inX;
  final double nodeX;
  final double outX;
  final int excludedMask;

  final int _inCount;
  final int _outCount;

  /// Per monitored input: its row's vertical centre on the canvas.
  final Map<int, double> _rowCenterY;

  bool excluded(int c) => excludedMask & (1 << c) != 0;
  double inY(int c) => canvasHeight / _inCount * (c + 0.5);
  double outY(int c) => canvasHeight / _outCount * (c + 0.5);
  double rowY(int input) => _rowCenterY[input]!;
  double addFxX(int input) {
    final xs = cardXs[input]!;
    return xs.isEmpty
        ? nodeX + monitorNodeWidth + cardGap
        : xs.last + cardWidth + cardGap;
  }

  /// Re-fit identity: a structural value list (compared with `listEquals`), so
  /// the canvas re-fits only when the row/effect counts or channel counts
  /// change — not when a row is focused or a mask toggled.
  List<Object?> get fitIdentity => [
    _inCount,
    _outCount,
    for (final c in rows) cardXs[c]!.length,
  ];
}
