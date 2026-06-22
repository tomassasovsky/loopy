import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:routing_graph/src/theme/routing_graph_theme.dart';
import 'package:routing_graph/src/widgets/focusable_tap_target.dart';

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
///
/// Pan/zoom is drag-driven, but a keyboard/single-pointer alternative
/// (WCAG 2.5.7) is always present: focusable zoom-in / zoom-out / fit buttons
/// overlaid in the corner.
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

  /// The last laid-out viewport size, used by the zoom/fit controls.
  Size _viewport = Size.zero;

  static const double _minScale = 0.3;
  static const double _maxScale = 3;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Matrix4 _fitMatrix(double vw, double vh) {
    var scale = vw / widget.width;
    if (widget.height * scale > vh) scale = vh / widget.height;
    if (scale > 1) scale = 1;
    return Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, (vw - widget.width * scale) / 2)
      ..setEntry(1, 3, (vh - widget.height * scale) / 2);
  }

  void _maybeFit(double vw, double vh) {
    if (vw <= 0 || vh <= 0) return;
    _viewport = Size(vw, vh);
    if (_fitted != null && listEquals(_fitted, widget.fitIdentity)) return;
    _fitted = widget.fitIdentity;
    final m = _fitMatrix(vw, vh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tc.value = m;
    });
  }

  /// Re-fits the content to the viewport (the keyboard "reset view" action).
  void _fit() {
    if (_viewport.isEmpty) return;
    _tc.value = _fitMatrix(_viewport.width, _viewport.height);
  }

  /// Scales about the viewport centre by [factor], clamped to the pan/zoom
  /// limits — the keyboard/button alternative to pinch-zoom.
  void _zoomBy(double factor) {
    if (_viewport.isEmpty) return;
    final current = _tc.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(_minScale, _maxScale);
    final applied = target / current;
    if (applied == 1) return;
    final cx = _viewport.width / 2;
    final cy = _viewport.height / 2;
    _tc.value = _tc.value.clone()
      ..translateByDouble(cx, cy, 0, 1)
      ..scaleByDouble(applied, applied, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.routingGraph;
    return GestureDetector(
      onTap: widget.onTapBackground,
      child: ColoredBox(
        color: theme.surface,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _maybeFit(constraints.maxWidth, constraints.maxHeight);
            return ClipRect(
              child: Stack(
                children: [
                  InteractiveViewer(
                    transformationController: _tc,
                    constrained: false,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    minScale: _minScale,
                    maxScale: _maxScale,
                    child: SizedBox(
                      width: widget.width,
                      height: widget.height,
                      child: Stack(children: widget.children),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: _ZoomControls(
                      onZoomIn: () => _zoomBy(1.25),
                      onZoomOut: () => _zoomBy(0.8),
                      onFit: _fit,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The corner zoom/fit control cluster: the keyboard/single-pointer alternative
/// to drag-pan/pinch-zoom (WCAG 2.5.7). Each button is focusable and labelled.
class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final theme = context.routingGraph;
    Widget button(Key key, IconData icon, String tooltip, VoidCallback onTap) {
      return Tooltip(
        message: tooltip,
        child: FocusableTapTarget(
          key: key,
          onTap: onTap,
          semanticLabel: tooltip,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(icon, size: 18, color: theme.textPrimary),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.card.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(
            const Key('graphCanvas_zoomOut'),
            Icons.remove,
            'Zoom out',
            onZoomOut,
          ),
          button(
            const Key('graphCanvas_fit'),
            Icons.fit_screen_outlined,
            'Fit to view',
            onFit,
          ),
          button(
            const Key('graphCanvas_zoomIn'),
            Icons.add,
            'Zoom in',
            onZoomIn,
          ),
        ],
      ),
    );
  }
}
