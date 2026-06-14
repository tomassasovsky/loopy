import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_graph_layout.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// An output port on the monitor graph whose colour and emphasis reflect which
/// monitor lanes route to it and whether the focused lane is wired to it.
///
/// Strong (and lane-coloured) when the focused lane plays here; coloured by its
/// single user when reached by exactly one lane; neutral accent when shared;
/// dim when unused. Mirrors the track lane graph's channel chip.
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

  /// The graph's `(input, lane)` rows, in row order.
  final List<MonitorRow> rows;

  /// The current monitor state (read for each row's output mask).
  final MonitorState state;

  /// The focused row, or null.
  final MonitorRow? focused;

  /// Wires/unwires the focused lane to this port; null when not interactive.
  final VoidCallback? onWire;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final bit = 1 << channel;
    final users = [
      for (final row in rows)
        if (state.forInput(row.input).lane(row.lane).outputMask & bit != 0) row,
    ];
    final strong = focused != null && users.contains(focused);
    final color = strong
        ? surface.laneColor(focused!.lane)
        : users.length == 1
        ? surface.laneColor(users.first.lane)
        : surface.accent;
    return ChannelChip(
      key: Key('monitorGraph_out_$channel'),
      label: label,
      color: color,
      strong: strong,
      wired: users.isNotEmpty,
      excluded: false,
      onTap: onWire,
    );
  }
}
