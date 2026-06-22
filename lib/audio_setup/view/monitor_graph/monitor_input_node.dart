import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// One monitored input's node: the input it monitors, a mute icon, and a
/// read-only volume level. Tapping it focuses the input (so its outputs become
/// wirable). Renders the input's single live chain — there is no lane stack.
class MonitorInputNode extends StatelessWidget {
  /// Creates a [MonitorInputNode].
  const MonitorInputNode({
    required this.input,
    required this.monitor,
    required this.color,
    required this.focused,
    required this.dim,
    required this.onTap,
    super.key,
  });

  /// The hardware input this node monitors.
  final int input;

  /// The monitor this node renders.
  final InputMonitor monitor;

  /// The input's accent colour.
  final Color color;

  /// Whether this input is currently focused.
  final bool focused;

  /// Whether another input is focused (so this one is dimmed).
  final bool dim;

  /// Focuses (or unfocuses) the input.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final volumeWord = monitor.muted
        ? l10n.trackStateMuted
        : '${(monitor.volume.clamp(0.0, 1.0) * 100).round()}%';
    return FocusableTapTarget(
      key: Key('monitorGraph_inputNode_$input'),
      onTap: onTap,
      selected: focused,
      borderRadius: 8,
      semanticLabel: '${l10n.inputMonitorLabel(input + 1)}, $volumeWord',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: focused ? 0.30 : 0.16),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: dim ? color.withValues(alpha: 0.5) : color,
            width: focused ? 2.5 : 1.5,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  monitor.muted ? Icons.volume_off : Icons.volume_up,
                  size: 13,
                  color: monitor.muted
                      ? surface.textTertiary
                      : surface.textSecondary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    l10n.inputMonitorLabel(input + 1),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: monitor.muted ? 0 : monitor.volume.clamp(0.0, 1.0),
                  backgroundColor: surface.line,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
