import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:routing_graph/src/theme/routing_graph_theme.dart';

/// A zoom/pan canvas for a routing graph: a fixed-size [width]×[height] stack of
/// positioned [children] inside an [InteractiveViewer], clipped and centred on
/// a surface-coloured background.
///
/// The canvas fits its content to the viewport once, and re-fits only when
/// [fitIdentity] changes. That identity is a **structural value list** (row
/// count, per-row effect counts, channel counts) compared with [listEquals] —
/// not a hashed int — so cosmetic changes (focusing a row, toggling a mask)
/// never trigger a re-fit, while adding a row/effect or a channel-count change
/// does.
class GraphCanvas extends StatefulWidget {
  /// Creates a graph canvas.
  const GraphCanvas({
    required this.width,
    required this.height,
    required this.fitIdentity,
    required this.children,
    this.onTapBackground,
    super.key,
  });

  /// The intrinsic width of the graph content.
  final double width;

  /// The intrinsic height of the graph content.
  final double height;

  /// The structural identity of the current layout; a change re-fits the view.
  final List<Object?> fitIdentity;

  /// The positioned graph contents (painter, nodes, cards).
  final List<Widget> children;

  /// Called when the user taps empty canvas (not a node or card), e.g. to clear
  /// the current selection. When null, background taps do nothing.
  final VoidCallback? onTapBackground;

  @override
  State<GraphCanvas> createState() => _GraphCanvasState();
}

class _GraphCanvasState extends State<GraphCanvas> {
  final TransformationController _tc = TransformationController();

  /// The [GraphCanvas.fitIdentity] the view was last fitted to, or null.
  List<Object?>? _fitted;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _maybeFit(double vw, double vh) {
    if (vw <= 0 || vh <= 0) return;
    if (_fitted != null && listEquals(_fitted, widget.fitIdentity)) return;
    _fitted = widget.fitIdentity;
    var scale = vw / widget.width;
    if (widget.height * scale > vh) scale = vh / widget.height;
    if (scale > 1) scale = 1;
    final m = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, (vw - widget.width * scale) / 2)
      ..setEntry(1, 3, (vh - widget.height * scale) / 2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tc.value = m;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTapBackground,
      child: ColoredBox(
        color: context.routingGraph.surface,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _maybeFit(constraints.maxWidth, constraints.maxHeight);
            return ClipRect(
              child: InteractiveViewer(
                transformationController: _tc,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                minScale: 0.3,
                maxScale: 3,
                child: SizedBox(
                  width: widget.width,
                  height: widget.height,
                  child: Stack(children: widget.children),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
