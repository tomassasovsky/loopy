import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/effect_params_editor.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// The docked controls below the canvas: the focused lane's vol/mute/remove,
/// the selected effect's editor, and the add-lane button.
class LanePanel extends StatelessWidget {
  /// Creates a [LanePanel].
  const LanePanel({
    required this.laneCount,
    required this.focused,
    required this.lanes,
    required this.selectedEffect,
    required this.onMuteToggled,
    required this.onVolumeChanged,
    required this.onRemoveLane,
    required this.onAddLane,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemoveEffect,
    super.key,
  });

  /// The number of lanes in the stack.
  final int laneCount;

  /// The focused lane index, or null.
  final int? focused;

  /// The track's lanes, in lane order.
  final List<Lane> lanes;

  /// The selected (open-in-the-editor) effect, as `(lane, index)`, or null.
  final ({int lane, int index})? selectedEffect;

  /// Per-lane mix.
  final void Function(int lane) onMuteToggled;
  final void Function(int lane, double volume) onVolumeChanged;

  /// Lane stack edits. Any lane can be removed while more than one exists.
  final void Function(int lane) onRemoveLane;
  final VoidCallback onAddLane;

  /// Effect-chain edits for the selected effect's lane.
  final void Function(int lane, int index, TrackEffectType type) onSetType;
  final void Function(int lane, int index, int param, double value) onSetParam;
  final void Function(int lane, int index) onRemoveEffect;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final f = focused;
    final sel = selectedEffect;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: surface.card,
        border: Border(top: BorderSide(color: surface.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (f != null && f < laneCount)
            Row(
              children: [
                Text(
                  'Lane ${f + 1}',
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  key: const Key('laneGraph_mute'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  iconSize: 18,
                  color: lanes[f].muted
                      ? surface.accent
                      : surface.textSecondary,
                  tooltip: lanes[f].muted ? 'Unmute lane' : 'Mute lane',
                  icon: Icon(
                    lanes[f].muted ? Icons.volume_off : Icons.volume_up,
                  ),
                  onPressed: () => onMuteToggled(f),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      activeTrackColor: surface.accent,
                      inactiveTrackColor: surface.line,
                      thumbColor: surface.accent,
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                    ),
                    child: Slider(
                      key: const Key('laneGraph_vol'),
                      value: lanes[f].volume.clamp(0.0, 1.0),
                      onChanged: (v) => onVolumeChanged(f, v),
                    ),
                  ),
                ),
                if (laneCount > 1)
                  IconButton(
                    key: const Key('laneGraph_removeLane'),
                    iconSize: 18,
                    color: surface.textSecondary,
                    tooltip: 'Remove lane',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => onRemoveLane(f),
                  ),
              ],
            )
          else
            Text(
              'Tap a lane to focus it, then tap inputs/outputs to wire it.',
              style: TextStyle(color: surface.textSecondary, fontSize: 13),
            ),
          if (sel != null &&
              sel.lane < laneCount &&
              sel.index < lanes[sel.lane].effects.length) ...[
            const SizedBox(height: 10),
            EffectParamsEditor(
              keyPrefix: 'laneGraph',
              fx: lanes[sel.lane].effects[sel.index],
              accentColor: surface.accent,
              onSetType: (t) => onSetType(sel.lane, sel.index, t),
              onSetParam: (p, v) => onSetParam(sel.lane, sel.index, p, v),
              onRemove: () => onRemoveEffect(sel.lane, sel.index),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('laneGraph_addLane'),
              onPressed: laneCount >= kMaxLanes ? null : onAddLane,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add lane'),
            ),
          ),
        ],
      ),
    );
  }
}
