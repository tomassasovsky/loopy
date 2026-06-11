import 'package:flutter/foundation.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/tracks_routing_graph/routing_graph.dart';

/// The routing change clicking a target channel while a track is armed
/// resolves to: which mask of which track [channel] to set to [mask].
@immutable
class RoutingEdit {
  /// Creates a [RoutingEdit].
  const RoutingEdit({
    required this.isInput,
    required this.channel,
    required this.mask,
  });

  /// The routing change clicking [target] resolves to for the armed [track], or
  /// null if [target] is not a connectable channel (a track, or an excluded
  /// loopback input). Toggles the corresponding mask bit.
  static RoutingEdit? forTarget(Track track, RoutingNode target) {
    final bit = 1 << target.index;
    return switch (target.kind) {
      RoutingNodeKind.input =>
        target.excluded
            ? null
            : RoutingEdit(
                isInput: true,
                channel: track.channel,
                mask: track.inputMask ^ bit,
              ),
      RoutingNodeKind.output => RoutingEdit(
        isInput: false,
        channel: track.channel,
        mask: track.outputMask ^ bit,
      ),
      RoutingNodeKind.track => null,
    };
  }

  /// Whether the input mask (`true`) or the output mask (`false`) changed.
  final bool isInput;

  /// The track channel whose routing changed.
  final int channel;

  /// The new bitmask value.
  final int mask;

  @override
  bool operator ==(Object other) =>
      other is RoutingEdit &&
      other.isInput == isInput &&
      other.channel == channel &&
      other.mask == mask;

  @override
  int get hashCode => Object.hash(isInput, channel, mask);
}
