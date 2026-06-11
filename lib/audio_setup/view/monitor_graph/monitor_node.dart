import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// A monitored input's node — "In N monitor · live · not recorded" — feeding
/// its effect chain. Tapping it focuses the input (so outputs become wirable).
class MonitorNode extends StatelessWidget {
  /// Creates a [MonitorNode].
  const MonitorNode({
    required this.input,
    required this.focused,
    required this.onTap,
    super.key,
  });

  /// The hardware input index this node monitors.
  final int input;

  /// Whether this input is currently focused.
  final bool focused;

  /// Focuses (or unfocuses) the input.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('monitorGraph_node_$input'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: surface.wetRoute.withValues(alpha: focused ? 0.3 : 0.16),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: surface.wetRoute,
              width: focused ? 2.5 : 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'In ${input + 1} monitor',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              Text(
                'live · not recorded',
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 10,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
