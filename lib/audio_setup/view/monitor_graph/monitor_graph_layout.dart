import 'dart:math' as math;

import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:routing_graph/routing_graph.dart';

/// One row of the monitor graph: a hardware input and one of its lane indices.
/// Records have value equality, so two rows are equal iff both fields match.
typedef MonitorRow = ({int input, int lane});

/// Pure geometry for one frame of the monitor graph: node positions, card
/// positions, and the wires. Computed once per build from the monitor state, so
/// the build method composes widgets instead of threading a dozen coordinates
/// around.
///
/// Structurally identical to the track lane graph: one row per `(input, lane)`,
/// each a node + its own effect chain, single per-lane-coloured edges over a
/// multi-row layout. There is no wet/dry duality — a lane with no effects is
/// simply the clean (dry) path.
@immutable
class MonitorGraphLayout {
  const MonitorGraphLayout._({
    required this.rows,
    required this.cardXs,
    required this.edges,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.inX,
    required this.nodeX,
    required this.outX,
    required this.excludedMask,
    required int inCount,
    required int outCount,
    required double rowsTop,
  }) : _inCount = inCount,
       _outCount = outCount,
       _rowsTop = rowsTop;

  factory MonitorGraphLayout.compute({
    required MonitorState state,
    required int inCount,
    required int outCount,
    required int excludedMask,
    required MonitorRow? focused,
    required List<Color> palette,
  }) {
    bool isExcluded(int c) => excludedMask & (1 << c) != 0;
    final rows = <MonitorRow>[
      for (var c = 0; c < inCount; c++)
        if (state.forInput(c).enabled && !isExcluded(c))
          for (var l = 0; l < state.forInput(c).laneCount; l++)
            (input: c, lane: l),
    ];

    const inX = padding;
    const nodeX = inX + channelChipWidth + fanGutter;

    final cardXs = [
      for (final row in rows)
        cardColumnXs(
          startX: cardStartX,
          count: state.forInput(row.input).lane(row.lane).effects.length,
          cardW: cardWidth,
          gap: cardGap,
        ),
    ];
    double addBtnXFor(int r) =>
        cardXs[r].isEmpty ? cardStartX : cardXs[r].last + cardWidth + cardGap;
    var widestRight = cardStartX;
    for (var r = 0; r < rows.length; r++) {
      widestRight = math.max(widestRight, addBtnXFor(r) + addSlotWidth);
    }
    final railX = widestRight;
    final outX = railX + fanGutter;
    final canvasWidth = outX + channelChipWidth + padding;

    final rowsBlockHeight = rows.length * rowHeight;
    final channelsHeight = math.max(inCount, outCount) * channelRowHeight;
    final canvasHeight =
        math.max(rowsBlockHeight, channelsHeight) + padding * 2;
    final rowsTop = (canvasHeight - rowsBlockHeight) / 2;

    double chYAt(int i, int count) => canvasHeight / count * (i + 0.5);
    double rowYAt(int r) => rowsTop + r * rowHeight + rowHeight / 2;
    Color laneColorAt(int lane) => palette[lane % palette.length];

    final edges = <GraphEdge>[];
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      final laneState = state.forInput(row.input).lane(row.lane);
      final y = rowYAt(r);
      final color = laneColorAt(row.lane);
      final faded = focused != null && focused != row;
      // input feed → lane node
      if (!isExcluded(row.input)) {
        edges.add(
          GraphEdge(
            Offset(inX + channelChipWidth, chYAt(row.input, inCount)),
            Offset(nodeX, y),
            color: color,
            faded: faded,
          ),
        );
      }
      // node → cards → tail
      final xs = cardXs[r];
      edges.addAll(
        chainEdges(
          nodeRight: nodeX + nodeWidth,
          y: y,
          cardXs: xs,
          cardW: cardWidth,
          color: color,
          faded: faded,
        ),
      );
      final rightX = xs.isEmpty ? nodeX + nodeWidth : xs.last + cardWidth;
      edges.addAll(
        fanEdges(
          sends: [
            GraphSend(
              originX: rightX,
              originY: y,
              mask: laneState.outputMask,
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

    return MonitorGraphLayout._(
      rows: rows,
      cardXs: cardXs,
      edges: edges,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      inX: inX,
      nodeX: nodeX,
      outX: outX,
      excludedMask: excludedMask,
      inCount: inCount,
      outCount: outCount,
      rowsTop: rowsTop,
    );
  }

  // Geometry constants. Inputs/outputs are small "channel" chips; each monitor
  // lane is a wider node feeding a horizontal chain of effect cards. The card
  // footprint comes from the shared kit metrics (kRoutingCard*).
  static const double channelChipWidth = 54;
  static const double channelChipHeight = 24;
  static const double channelRowHeight = 32; // vertical pitch between chips
  static const double nodeWidth = 128;
  static const double nodeHeight = 50;
  static const double rowHeight = 84; // vertical pitch between lane rows
  static const double cardWidth = kRoutingCardWidth;
  static const double cardGap = kRoutingCardGap;
  static const double fanGutter = 120; // input→node / rail→output gutter
  static const double addSlotWidth = kRoutingAddSlot;
  static const double padding = 16;

  /// The x of the first effect card (also the empty-chain drop spot).
  static const double cardStartX =
      padding + channelChipWidth + fanGutter + nodeWidth + cardGap;

  /// The graph's rows, in `(input, lane)` order.
  final List<MonitorRow> rows;

  /// Per row: the x of each effect card.
  final List<List<double>> cardXs;

  /// The wires to paint.
  final List<GraphEdge> edges;

  final double canvasWidth;
  final double canvasHeight;
  final double inX;
  final double nodeX;
  final double outX;
  final int excludedMask;

  final int _inCount;
  final int _outCount;
  final double _rowsTop;

  bool excluded(int c) => excludedMask & (1 << c) != 0;
  double inY(int c) => canvasHeight / _inCount * (c + 0.5);
  double outY(int c) => canvasHeight / _outCount * (c + 0.5);
  double rowY(int r) => _rowsTop + r * rowHeight + rowHeight / 2;
  double addFxX(int r) =>
      cardXs[r].isEmpty ? cardStartX : cardXs[r].last + cardWidth + cardGap;

  /// Re-fit identity: a structural value list (compared with `listEquals`), so
  /// the canvas re-fits only when the row/effect counts or channel counts
  /// change — not when a row is focused or a mask toggled.
  List<Object?> get fitIdentity => [
    _inCount,
    _outCount,
    rows.length,
    for (final xs in cardXs) xs.length,
  ];
}
