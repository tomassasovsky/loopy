import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';

/// A compact per-track I/O routing control: toggle which hardware input channels
/// a track records from (averaged into its mono buffer) and which hardware
/// output channels it plays to.
///
/// Presentational and self-contained — it reports changes through
/// [onInputMaskChanged] / [onOutputMaskChanged] so it can be driven by a bloc
/// (in the app) or asserted directly (in tests).
class TrackRoutingPanel extends StatelessWidget {
  /// Creates a [TrackRoutingPanel].
  const TrackRoutingPanel({
    required this.track,
    required this.inputChannels,
    required this.outputChannels,
    required this.onInputMaskChanged,
    required this.onOutputMaskChanged,
    super.key,
  });

  /// The track whose routing is being edited.
  final Track track;

  /// Number of available hardware input channels.
  final int inputChannels;

  /// Number of available hardware output channels.
  final int outputChannels;

  /// Called with the newly toggled input bitmask.
  final ValueChanged<int> onInputMaskChanged;

  /// Called with the newly toggled output bitmask.
  final ValueChanged<int> onOutputMaskChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Fall back to at least the track's current routing when the engine isn't
    // running (channel counts are 0), so the panel still shows a usable choice.
    final inCount = inputChannels > 0
        ? inputChannels
        : track.inputMask.bitLength.clamp(1, 32);
    final outCount = outputChannels > 0
        ? outputChannels
        : track.outputMask.bitLength.clamp(2, 32);

    return Column(
      key: const Key('trackRouting_panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Input sources', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var c = 0; c < inCount; c++)
              FilterChip(
                key: Key('trackRouting_input_chip_$c'),
                label: Text('In ${c + 1}'),
                selected: track.inputMask & (1 << c) != 0,
                onSelected: (selected) => onInputMaskChanged(
                  selected
                      ? track.inputMask | (1 << c)
                      : track.inputMask & ~(1 << c),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Output channels', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var c = 0; c < outCount; c++)
              FilterChip(
                key: Key('trackRouting_output_chip_$c'),
                label: Text('Out ${c + 1}'),
                selected: track.outputMask & (1 << c) != 0,
                onSelected: (selected) => onOutputMaskChanged(
                  selected
                      ? track.outputMask | (1 << c)
                      : track.outputMask & ~(1 << c),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
