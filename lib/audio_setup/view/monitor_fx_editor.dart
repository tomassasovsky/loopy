import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/setup/setup_surface.dart';

/// The per-input live-monitor controls for one hardware [input]: an enable
/// toggle, output routing, and a flat, drag-reorderable effect chain. The
/// monitored signal runs live through its own chain and is never recorded;
/// monitoring is independent of any track's record/playback state.
class InputMonitorTile extends StatelessWidget {
  /// Creates an [InputMonitorTile] for hardware [input].
  const InputMonitorTile({
    required this.input,
    required this.outputChannels,
    super.key,
  });

  /// The hardware input channel this tile configures.
  final int input;

  /// The number of hardware output channels available for routing.
  final int outputChannels;

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<MonitorCubit>().state.forInput(input);
    return Container(
      key: Key('audioSettings_monitorInput_$input'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SetupToggleRow(
            toggleKey: Key('audioSettings_monitorInput_switch_$input'),
            title: 'Input ${input + 1}',
            subtitle: 'Monitor this input live through its own effects',
            value: monitor.enabled,
            onChanged: (on) => unawaited(
              context.read<MonitorCubit>().setEnabled(input, enabled: on),
            ),
          ),
          if (monitor.enabled) ...[
            const SizedBox(height: 12),
            const Text('Effected signal to these outputs', style: setupBody),
            const SizedBox(height: 8),
            SetupChannelChips(
              keyPrefix: 'audioSettings_monitorOut_$input',
              channelCount: outputChannels,
              mask: monitor.outputMask,
              onChanged: (m) => unawaited(
                context.read<MonitorCubit>().setOutputMask(input, m),
              ),
            ),
            const SizedBox(height: 12),
            _MonitorFxList(input: input),
            const SizedBox(height: 12),
            const Text(
              'Dry (clean) signal to these outputs',
              style: setupBody,
            ),
            const SizedBox(height: 4),
            const Text(
              'A parallel send of the unprocessed input — hear it clean and '
              'effected at once.',
              style: TextStyle(color: SetupSurfaceColors.t3, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SetupChannelChips(
              keyPrefix: 'audioSettings_monitorDry_$input',
              channelCount: outputChannels,
              mask: monitor.dryOutputMask,
              onChanged: (m) => unawaited(
                context.read<MonitorCubit>().setDryOutputMask(input, m),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The flat, drag-reorderable monitor-FX chain for one hardware [input].
class _MonitorFxList extends StatelessWidget {
  const _MonitorFxList({required this.input});

  final int input;

  @override
  Widget build(BuildContext context) {
    final effects = context.watch<MonitorCubit>().state.forInput(input).effects;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Monitor FX', style: setupBody)),
            TextButton.icon(
              key: Key('audioSettings_monitorFx_add_$input'),
              onPressed: () => context.read<MonitorCubit>().addEffect(input),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              style: TextButton.styleFrom(
                foregroundColor: SetupSurfaceColors.accent,
              ),
            ),
          ],
        ),
        if (effects.isEmpty)
          Padding(
            key: Key('audioSettings_monitorFx_empty_$input'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: const Text(
              'No monitor effects. Add one to color this input live — '
              'never recorded.',
              style: TextStyle(color: SetupSurfaceColors.t2, fontSize: 13),
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: effects.length,
            onReorderItem: (from, to) =>
                context.read<MonitorCubit>().moveEffect(input, from, to),
            itemBuilder: (context, i) => _MonitorFxCard(
              key: ValueKey('monitorFx_${input}_$i'),
              input: input,
              index: i,
            ),
          ),
      ],
    );
  }
}

class _MonitorFxCard extends StatelessWidget {
  const _MonitorFxCard({
    required this.input,
    required this.index,
    super.key,
  });

  final int input;
  final int index;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MonitorCubit>();
    final fx = cubit.state.forInput(input).effects[index];
    return Container(
      key: Key('audioSettings_monitorFx_card_${input}_$index'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.cardHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SetupSurfaceColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Icon(
                    Icons.drag_indicator,
                    size: 16,
                    color: SetupSurfaceColors.t3,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: DropdownButton<TrackEffectType>(
                  key: Key('audioSettings_monitorFx_type_${input}_$index'),
                  isExpanded: true,
                  isDense: true,
                  value: fx.type,
                  dropdownColor: SetupSurfaceColors.cardHi,
                  style: const TextStyle(
                    color: SetupSurfaceColors.t1,
                    fontSize: 14,
                  ),
                  onChanged: (type) {
                    if (type != null && type != TrackEffectType.none) {
                      cubit.setEffectType(input, index, type);
                    }
                  },
                  items: [
                    for (final type in TrackEffectType.values)
                      if (type != TrackEffectType.none)
                        DropdownMenuItem(
                          value: type,
                          child: Text(type.label),
                        ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Remove effect',
                child: InkResponse(
                  key: Key('audioSettings_monitorFx_remove_${input}_$index'),
                  onTap: () => cubit.removeEffect(input, index),
                  radius: 18,
                  child: const SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: SetupSurfaceColors.t2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          for (var p = 0; p < fx.type.paramLabels.length; p++)
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      fx.type.paramLabels[p],
                      style: const TextStyle(
                        color: SetupSurfaceColors.t2,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        activeTrackColor: SetupSurfaceColors.accent,
                        inactiveTrackColor: SetupSurfaceColors.line,
                        thumbColor: SetupSurfaceColors.accent,
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                      ),
                      child: Slider(
                        key: Key(
                          'audioSettings_monitorFx_param_${input}_${index}_$p',
                        ),
                        value: fx.params[p].clamp(0.0, 1.0),
                        onChanged: (v) =>
                            cubit.setEffectParam(input, index, p, v),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
