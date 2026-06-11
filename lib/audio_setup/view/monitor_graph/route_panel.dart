import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/view/monitor_graph/route_legend.dart';
import 'package:loopy/common/effect_params_editor.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// The docked controls below the canvas: a hint when nothing is focused, else
/// the focused input's Effected/Dry toggle, Stop button, selected-effect editor,
/// and the wet/dry legend.
class RoutePanel extends StatelessWidget {
  /// Creates a [RoutePanel].
  const RoutePanel({
    required this.monitor,
    required this.wireDry,
    required this.selectedFx,
    required this.onWireModeChanged,
    required this.onStop,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemove,
    super.key,
  });

  /// The focused input's monitor state, or null when nothing is focused.
  final InputMonitor? monitor;

  /// Which send an output tap wires for the focused input: wet (false) or dry.
  final bool wireDry;

  /// The selected (open-in-the-editor) effect, or null.
  final TrackEffect? selectedFx;

  /// Picks which send an output tap wires.
  final ValueChanged<bool> onWireModeChanged;

  /// Stops monitoring the focused input.
  final VoidCallback onStop;

  /// Effect-chain edits for the selected effect.
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final m = monitor;
    final focused = m?.enabled ?? false;
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
          if (!focused || m == null)
            Text(
              'Tap an input to monitor it, then tap outputs to send it there.',
              style: TextStyle(color: surface.textSecondary, fontSize: 13),
            )
          else
            Row(
              children: [
                Text(
                  'In ${m.input + 1} monitor',
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                SegmentedButton<bool>(
                  key: const Key('monitorGraph_routeToggle'),
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Effected'),
                      icon: Icon(Icons.graphic_eq, size: 16),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Dry'),
                      icon: Icon(Icons.water_drop_outlined, size: 16),
                    ),
                  ],
                  selected: {wireDry},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => onWireModeChanged(s.first),
                ),
                const Spacer(),
                TextButton.icon(
                  key: const Key('monitorGraph_stop'),
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('Stop'),
                  style: TextButton.styleFrom(
                    foregroundColor: surface.textSecondary,
                  ),
                ),
              ],
            ),
          if (focused && selectedFx != null) ...[
            const SizedBox(height: 10),
            EffectParamsEditor(
              keyPrefix: 'monitorGraph',
              fx: selectedFx!,
              accentColor: surface.wetRoute,
              onSetType: onSetType,
              onSetParam: onSetParam,
              onRemove: onRemove,
            ),
          ],
          const SizedBox(height: 10),
          const RouteLegend(),
        ],
      ),
    );
  }
}
