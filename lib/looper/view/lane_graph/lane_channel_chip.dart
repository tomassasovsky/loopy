import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// A hardware port on the lane graph — an input or output [ChannelChip] whose
/// colour and emphasis reflect which lanes use it and whether the focused lane
/// is wired to it.
///
/// Strong (and lane-coloured) when the focused lane uses this port; coloured by
/// its single user when shared by exactly one lane; neutral accent when shared;
/// dim when unused.
class LaneChannelChip extends StatelessWidget {
  /// Creates a [LaneChannelChip].
  const LaneChannelChip({
    required this.label,
    required this.channel,
    required this.lanes,
    required this.focused,
    required this.output,
    required this.excluded,
    required this.onWire,
    super.key,
  });

  /// The chip's caption (e.g. `In 1`).
  final String label;

  /// The hardware channel index this port represents.
  final int channel;

  /// The track's lanes, in lane order.
  final List<Lane> lanes;

  /// The focused lane index, or null.
  final int? focused;

  /// Whether this is an output port (vs. an input port).
  final bool output;

  /// Whether this port is a loopback input (drawn dimmed, never wired).
  final bool excluded;

  /// Wires/unwires the focused lane to this port; null when not interactive.
  final VoidCallback? onWire;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    // Lanes recording from / playing to this port.
    final users = excluded
        ? const <int>[]
        : [
            for (var l = 0; l < lanes.length; l++)
              if (output
                  ? lanes[l].outputMask & (1 << channel) != 0
                  : lanes[l].inputChannel == channel)
                l,
          ];
    final strong = focused != null && users.contains(focused);
    final color = strong
        ? surface.laneColor(focused!)
        : users.length == 1
        ? surface.laneColor(users.first)
        : surface.accent;
    return ChannelChip(
      key: Key('laneGraph_${output ? 'out' : 'in'}_$channel'),
      label: label,
      color: color,
      strong: strong,
      wired: users.isNotEmpty,
      excluded: excluded,
      onTap: onWire,
    );
  }
}
