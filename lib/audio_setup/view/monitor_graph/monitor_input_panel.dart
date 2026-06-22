import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/effect_params_editor.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// The docked controls below the canvas: a hint when nothing is focused, else
/// the focused input's vol/mute, a Stop button to disable the whole input, and
/// the selected effect's editor. Renders the input's single live chain — the
/// chain that is snapshot-copied onto a lane when you record this input.
class MonitorInputPanel extends StatelessWidget {
  /// Creates a [MonitorInputPanel].
  const MonitorInputPanel({
    required this.input,
    required this.monitor,
    required this.selectedFx,
    required this.onMuteToggled,
    required this.onVolumeChanged,
    required this.onStop,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemoveEffect,
    this.addedLatencyMs = 0,
    super.key,
  });

  /// The focused hardware input, or null when nothing is focused.
  final int? input;

  /// The focused input's monitor state, or null when nothing is focused.
  final InputMonitor? monitor;

  /// The selected (open-in-the-editor) effect, or null.
  final TrackEffect? selectedFx;

  /// Mix controls.
  final VoidCallback onMuteToggled;
  final ValueChanged<double> onVolumeChanged;

  /// Disables monitoring of the focused input entirely.
  final VoidCallback onStop;

  /// Effect-chain edits for the selected effect.
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemoveEffect;

  /// The engine's reported added latency (ms) for the octaver monitoring hint.
  final double addedLatencyMs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final i = input;
    final m = monitor;
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
          if (i == null || m == null)
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
                IconButton(
                  key: const Key('monitorGraph_mute'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  iconSize: 18,
                  color: m.muted ? surface.accent : surface.textSecondary,
                  tooltip: m.muted
                      ? l10n.unmuteInputTooltip
                      : l10n.muteInputTooltip,
                  icon: Icon(m.muted ? Icons.volume_off : Icons.volume_up),
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
                      value: m.volume.clamp(0.0, 1.0),
                      onChanged: onVolumeChanged,
                    ),
                  ),
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
                addedLatencyMs: addedLatencyMs,
                onSetType: onSetType,
                onSetParam: onSetParam,
                onRemove: onRemoveEffect,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
