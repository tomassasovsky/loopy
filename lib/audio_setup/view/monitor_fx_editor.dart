import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/setup/setup_surface.dart';

/// The monitor-FX bus editor: a compact, ordered list of effect cards applied
/// to the live monitored signal in every mode (custom masks or follow-track).
/// Unlike the per-track routing graph there is no pre/post — the bus is a single
/// flat chain — so this is a simple vertical, drag-reorderable list rather than
/// a signal-flow graph.
class MonitorFxEditor extends StatelessWidget {
  /// Creates a [MonitorFxEditor].
  const MonitorFxEditor({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<MonitorCubit>();
    final effects = cubit.state.effects;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Monitor FX', style: setupBody)),
            TextButton.icon(
              key: const Key('audioSettings_monitorFx_add'),
              onPressed: context.read<MonitorCubit>().addEffect,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              style: TextButton.styleFrom(
                foregroundColor: SetupSurfaceColors.accent,
              ),
            ),
          ],
        ),
        if (effects.isEmpty)
          const Padding(
            key: Key('audioSettings_monitorFx_empty'),
            padding: EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              'No monitor effects. Add one to color your live input — heard '
              'in every monitor mode, never recorded.',
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
                context.read<MonitorCubit>().moveEffect(from, to),
            itemBuilder: (context, i) =>
                _MonitorFxCard(key: ValueKey('monitorFx_$i'), index: i),
          ),
      ],
    );
  }
}

class _MonitorFxCard extends StatelessWidget {
  const _MonitorFxCard({required this.index, super.key});

  final int index;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MonitorCubit>();
    final fx = cubit.state.effects[index];
    return Container(
      key: Key('audioSettings_monitorFx_card_$index'),
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
                  key: Key('audioSettings_monitorFx_type_$index'),
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
                      cubit.setEffectType(index, type);
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
                  key: Key('audioSettings_monitorFx_remove_$index'),
                  onTap: () => cubit.removeEffect(index),
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
                        key: Key('audioSettings_monitorFx_param_${index}_$p'),
                        value: fx.params[p].clamp(0.0, 1.0),
                        onChanged: (v) => cubit.setEffectParam(index, p, v),
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
