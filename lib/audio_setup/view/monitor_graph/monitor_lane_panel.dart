import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/effect_params_editor.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// The docked controls below the canvas: a hint when nothing is focused, else
/// the focused monitor lane's vol/mute/remove-lane, a Stop button to disable the
/// whole input, the selected effect's editor, and the add-lane button. Mirrors
/// the track lane panel.
class MonitorLanePanel extends StatelessWidget {
  /// Creates a [MonitorLanePanel].
  const MonitorLanePanel({
    required this.input,
    required this.lane,
    required this.laneState,
    required this.laneCount,
    required this.selectedFx,
    required this.onMuteToggled,
    required this.onVolumeChanged,
    required this.onRemoveLane,
    required this.onAddLane,
    required this.onStop,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemoveEffect,
    super.key,
  });

  /// The focused row's hardware input, or null when nothing is focused.
  final int? input;

  /// The focused row's lane index (meaningful only when [input] is non-null).
  final int lane;

  /// The focused monitor lane's state, or null when nothing is focused.
  final MonitorLane? laneState;

  /// The focused input's active lane count.
  final int laneCount;

  /// The selected (open-in-the-editor) effect, or null.
  final TrackEffect? selectedFx;

  /// Per-lane mix.
  final VoidCallback onMuteToggled;
  final ValueChanged<double> onVolumeChanged;

  /// Lane-stack edits for the focused input.
  final VoidCallback onRemoveLane;
  final VoidCallback onAddLane;

  /// Disables monitoring of the focused input entirely.
  final VoidCallback onStop;

  /// Effect-chain edits for the selected effect.
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemoveEffect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final i = input;
    final l = laneState;
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
          if (i == null || l == null)
            Text(
              l10n.monitorGraphHint,
              style: TextStyle(color: surface.textSecondary, fontSize: 13),
            )
          else ...[
            Row(
              children: [
                Text(
                  l10n.inputMonitorLabel(i + 1),
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.laneNumberLabel(lane + 1),
                  style: TextStyle(color: surface.textSecondary, fontSize: 13),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('monitorGraph_mute'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  iconSize: 18,
                  color: l.muted ? surface.accent : surface.textSecondary,
                  tooltip: l.muted
                      ? l10n.unmuteLaneTooltip
                      : l10n.muteLaneTooltip,
                  icon: Icon(l.muted ? Icons.volume_off : Icons.volume_up),
                  onPressed: onMuteToggled,
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
                      key: const Key('monitorGraph_volume'),
                      value: l.volume.clamp(0.0, 1.0),
                      onChanged: onVolumeChanged,
                    ),
                  ),
                ),
                if (laneCount > 1)
                  IconButton(
                    key: const Key('monitorGraph_removeLane'),
                    iconSize: 18,
                    color: surface.textSecondary,
                    tooltip: l10n.removeLaneTooltip,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onRemoveLane,
                  ),
                TextButton.icon(
                  key: const Key('monitorGraph_stop'),
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: Text(l10n.stopButton),
                  style: TextButton.styleFrom(
                    foregroundColor: surface.textSecondary,
                  ),
                ),
              ],
            ),
            if (selectedFx != null) ...[
              const SizedBox(height: 10),
              EffectParamsEditor(
                keyPrefix: 'monitorGraph',
                fx: selectedFx!,
                accentColor: surface.accent,
                onSetType: onSetType,
                onSetParam: onSetParam,
                onRemove: onRemoveEffect,
              ),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('monitorGraph_addLane'),
                onPressed: laneCount >= kMaxLanes ? null : onAddLane,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.addLane),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
