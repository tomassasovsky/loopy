import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart';

/// Pure geometry for one frame of the lane graph: node positions, card
/// positions, and the wires — computed once per build so the widget tree is
/// plain assembly.
@immutable
class LaneGraphLayout {
  const LaneGraphLayout._({
    required this.cardXs,
    required this.edges,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.inX,
    required this.laneX,
    required this.outX,
    required int inCount,
    required int outCount,
    required int laneCount,
    required double lanesTop,
  }) : _inCount = inCount,
       _outCount = outCount,
       _laneCount = laneCount,
       _lanesTop = lanesTop;

  factory LaneGraphLayout.compute({
    required List<Lane> lanes,
    required int inCount,
    required int outCount,
    required int excludedMask,
    required int? focused,
    required List<Color> palette,
  }) {
    const inX = padding;
    const laneX = inX + channelChipWidth + fanGutter;
    final laneCount = lanes.length;

    final cardXs = [
      for (final lane in lanes)
        cardColumnXs(
          startX: cardStartX,
          count: lane.effects.length,
          cardW: cardWidth,
          gap: cardGap,
        ),
    ];
    double addBtnXFor(int l) =>
        cardXs[l].isEmpty ? cardStartX : cardXs[l].last + cardWidth + cardGap;
    var widestRight = cardStartX;
    for (var l = 0; l < laneCount; l++) {
      widestRight = widestRight > addBtnXFor(l) + addSlotWidth
          ? widestRight
          : addBtnXFor(l) + addSlotWidth;
    }
    final outX = widestRight + fanGutter;
    final railX = outX - fanGutter;
    final canvasWidth = outX + channelChipWidth + padding;

    final lanesBlockHeight = laneCount * laneRowHeight;
    final channelsHeight =
        (inCount > outCount ? inCount : outCount) * channelRowHeight;
    final canvasHeight =
        (lanesBlockHeight > channelsHeight
            ? lanesBlockHeight
            : channelsHeight) +
        padding * 2;
    final lanesTop = (canvasHeight - lanesBlockHeight) / 2;

    double laneYAt(int l) => lanesTop + l * laneRowHeight + laneRowHeight / 2;
    double chYAt(int i, int count) => canvasHeight / count * (i + 0.5);
    Color laneColorAt(int l) => palette[l % palette.length];

    final edges = <GraphEdge>[];
    for (var l = 0; l < laneCount; l++) {
      final lane = lanes[l];
      final y = laneYAt(l);
      final color = laneColorAt(l);
      final faded = focused != null && focused != l;
      // input -> lane
      final c = lane.inputChannel;
      if (c >= 0 && c < inCount && excludedMask & (1 << c) == 0) {
        edges.add(
          GraphEdge(
            Offset(inX + channelChipWidth, chYAt(c, inCount)),
            Offset(laneX, y),
            color: color,
            faded: faded,
          ),
        );
      }
      final xs = cardXs[l];
      edges.addAll(
        chainEdges(
          nodeRight: laneX + laneNodeWidth,
          y: y,
          cardXs: xs,
          cardW: cardWidth,
          color: color,
          faded: faded,
        ),
      );
      final rightX = xs.isEmpty ? laneX + laneNodeWidth : xs.last + cardWidth;
      edges.addAll(
        fanEdges(
          sends: [
            GraphSend(
              originX: rightX,
              originY: y,
              mask: lane.outputMask,
              color: color,
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

    return LaneGraphLayout._(
      cardXs: cardXs,
      edges: edges,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      inX: inX,
      laneX: laneX,
      outX: outX,
      inCount: inCount,
      outCount: outCount,
      laneCount: laneCount,
      lanesTop: lanesTop,
    );
  }

  // Geometry constants. The card footprint comes from the shared kit metrics.
  static const double channelChipWidth = 54;
  static const double channelChipHeight = 24;
  static const double laneNodeWidth = 120;
  static const double laneNodeHeight = 50;
  static const double cardWidth = kRoutingCardWidth;
  static const double cardGap = kRoutingCardGap;
  static const double fanGutter = 92;
  static const double addSlotWidth = kRoutingAddSlot;
  static const double laneRowHeight = 84;
  static const double channelRowHeight = 32;
  static const double padding = 16;

  /// The x of the first effect card (also the empty-chain drop spot).
  static const double cardStartX =
      padding + channelChipWidth + fanGutter + laneNodeWidth + cardGap;

  /// Per lane: the x of each effect card.
  final List<List<double>> cardXs;

  /// The wires to paint.
  final List<GraphEdge> edges;

  final double canvasWidth;
  final double canvasHeight;
  final double inX;
  final double laneX;
  final double outX;

  final int _inCount;
  final int _outCount;
  final int _laneCount;
  final double _lanesTop;

  double laneY(int l) => _lanesTop + l * laneRowHeight + laneRowHeight / 2;
  double inY(int c) => canvasHeight / _inCount * (c + 0.5);
  double outY(int c) => canvasHeight / _outCount * (c + 0.5);
  double addBtnX(int l) =>
      cardXs[l].isEmpty ? cardStartX : cardXs[l].last + cardWidth + cardGap;

  /// Re-fit identity: a structural value list (compared with `listEquals`).
  List<Object?> get fitIdentity => [
    _laneCount,
    for (final xs in cardXs) xs.length,
    _inCount,
    _outCount,
  ];
}
