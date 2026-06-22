import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// One monitor lane's node: the input it monitors, its lane number, a mute
/// icon, and a read-only volume level. Tapping it focuses the lane (so its
/// outputs become wirable). Mirrors the track lane node, minus recording.
class MonitorLaneNode extends StatelessWidget {
  /// Creates a [MonitorLaneNode].
  const MonitorLaneNode({
    required this.input,
    required this.lane,
    required this.laneState,
    required this.color,
    required this.focused,
    required this.dim,
    required this.onTap,
    super.key,
  });

  /// The hardware input this lane monitors.
  final int input;

  /// The lane's position within the input.
  final int lane;

  /// The monitor lane this node renders.
  final MonitorLane laneState;

  /// The lane's accent colour.
  final Color color;

  /// Whether this lane is currently focused.
  final bool focused;

  /// Whether another lane is focused (so this one is dimmed).
  final bool dim;

  /// Focuses (or unfocuses) the lane.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final volumeWord = laneState.muted
        ? l10n.trackStateMuted
        : '${(laneState.volume.clamp(0.0, 1.0) * 100).round()}%';
    return FocusableTapTarget(
      key: Key('monitorGraph_laneNode_${input}_$lane'),
      onTap: onTap,
      selected: focused,
      borderRadius: 8,
      semanticLabel:
          '${l10n.inputMonitorLabel(input + 1)}, '
          '${l10n.laneNumberLabel(lane + 1)}, $volumeWord',
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
                  laneState.muted ? Icons.volume_off : Icons.volume_up,
                  size: 13,
                  color: laneState.muted
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
            Text(
              l10n.laneNumberLabel(lane + 1),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 10,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: laneState.muted ? 0 : laneState.volume.clamp(0.0, 1.0),
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
