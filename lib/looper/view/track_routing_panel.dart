import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';

/// A compact per-track I/O routing control: choose the hardware input channel a
/// track records from, and toggle which hardware output channels it plays to.
///
/// Presentational and self-contained — it reports changes through [onInput
/// Changed] / [onOutputMaskChanged] so it can be driven by a bloc (in the app)
/// or asserted directly (in tests).
class TrackRoutingPanel extends StatelessWidget {
  /// Creates a [TrackRoutingPanel].
  const TrackRoutingPanel({
    required this.track,
    required this.inputChannels,
    required this.outputChannels,
    required this.onInputChanged,
    required this.onOutputMaskChanged,
    super.key,
  });

  /// The track whose routing is being edited.
  final Track track;

  /// Number of available hardware input channels.
  final int inputChannels;

  /// Number of available hardware output channels.
  final int outputChannels;

  /// Called with the newly selected record-source input channel.
  final ValueChanged<int> onInputChanged;

  /// Called with the newly toggled output bitmask.
  final ValueChanged<int> onOutputMaskChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Fall back to at least the track's current routing when the engine isn't
    // running (channel counts are 0), so the panel still shows a usable choice.
    final inCount = inputChannels > 0 ? inputChannels : track.inputChannel + 1;
    // When the engine isn't running, show at least a stereo pair, expanded to
    // cover the highest channel the saved mask already targets.
    final outCount = outputChannels > 0
        ? outputChannels
        : track.outputMask.bitLength.clamp(2, 32);

    return Column(
      key: const Key('trackRouting_panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Input source', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        DropdownButton<int>(
          key: const Key('trackRouting_input_dropdown'),
          value: track.inputChannel.clamp(0, inCount - 1),
          isExpanded: true,
          items: [
            for (var c = 0; c < inCount; c++)
              DropdownMenuItem<int>(value: c, child: Text('Input ${c + 1}')),
          ],
          onChanged: (value) {
            if (value != null) onInputChanged(value);
          },
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
