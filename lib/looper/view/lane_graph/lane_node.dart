import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// A lane's node: its name, mute icon, and a read-only volume level. Tapping it
/// focuses the lane (so inputs/outputs become wirable).
class LaneNode extends StatelessWidget {
  /// Creates a [LaneNode].
  const LaneNode({
    required this.index,
    required this.lane,
    required this.color,
    required this.focused,
    required this.dim,
    required this.onTap,
    super.key,
  });

  /// The lane's position in the stack.
  final int index;

  /// The lane this node renders.
  final Lane lane;

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
    final volumeWord = lane.muted
        ? l10n.trackStateMuted
        : '${(lane.volume.clamp(0.0, 1.0) * 100).round()}%';
    // A recorded lane carries a snapshot of the input's FX chain taken at the
    // record moment (distinct from the live input chip). Surface it when the
    // lane has an effect chain and a known recorded input (D10/F-4).
    final snapshotLabel = lane.effects.isNotEmpty && lane.inputChannel >= 0
        ? l10n.laneSnapshotLabel(lane.inputChannel + 1)
        : null;
    return FocusableTapTarget(
      key: Key('laneGraph_laneNode_$index'),
      onTap: onTap,
      selected: focused,
      borderRadius: 8,
      semanticLabel: snapshotLabel == null
          ? '${l10n.laneNumberLabel(index + 1)}, $volumeWord'
          : '${l10n.laneNumberLabel(index + 1)}, $volumeWord, $snapshotLabel',
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
                  lane.muted ? Icons.volume_off : Icons.volume_up,
                  size: 13,
                  color: lane.muted
                      ? surface.textTertiary
                      : surface.textSecondary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    l10n.laneNumberLabel(index + 1),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (snapshotLabel != null) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: snapshotLabel,
                    child: Icon(
                      key: const Key('laneGraph_snapshotBadge'),
                      Icons.auto_awesome,
                      size: 11,
                      color: surface.accent,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: lane.muted ? 0 : lane.volume.clamp(0.0, 1.0),
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
