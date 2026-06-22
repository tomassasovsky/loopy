import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_graph_layout.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// An output port on the monitor graph whose colour and emphasis reflect which
/// monitored inputs route to it and whether the focused input is wired to it.
///
/// Strong (and input-coloured) when the focused input plays here; coloured by
/// its single user when reached by exactly one input; neutral accent when
/// shared; dim when unused. Mirrors the track lane graph's channel chip.
class MonitorOutputChip extends StatelessWidget {
  /// Creates a [MonitorOutputChip].
  const MonitorOutputChip({
    required this.label,
    required this.channel,
    required this.rows,
    required this.state,
    required this.focused,
    required this.onWire,
    super.key,
  });

  /// The chip's caption (e.g. `Out 1`).
  final String label;

  /// The hardware output channel index this port represents.
  final int channel;

  /// The graph's monitored-input rows, in row order.
  final List<MonitorRow> rows;

  /// The current monitor state (read for each input's output mask).
  final MonitorState state;

  /// The focused input, or null.
  final MonitorRow? focused;

  /// Wires/unwires the focused input to this port; null when not interactive.
  final VoidCallback? onWire;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final bit = 1 << channel;
    final users = [
      for (final input in rows)
        if (state.forInput(input).outputMask & bit != 0) input,
    ];
    final strong = focused != null && users.contains(focused);
    final color = strong
        ? surface.laneColor(focused!)
        : users.length == 1
        ? surface.laneColor(users.first)
        : surface.accent;
    // Output sharing is otherwise colour-only (WCAG 1.4.1); name it.
    final l10n = context.l10n;
    final sharingWord = users.isEmpty
        ? l10n.a11yPortUnused
        : users.length == 1
        ? l10n.a11yPortDedicated
        : l10n.a11yPortShared;
    return ChannelChip(
      key: Key('monitorGraph_out_$channel'),
      label: label,
      semanticLabel: '$label, $sharingWord',
      color: color,
      strong: strong,
      wired: users.isNotEmpty,
      excluded: false,
      onTap: onWire,
    );
  }
}
