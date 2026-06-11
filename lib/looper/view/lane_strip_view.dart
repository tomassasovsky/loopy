import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/setup/setup_surface.dart';

/// One lane of a track, drawn as a compact signal-flow strip:
///
///   In ▾ → ● Lane (vol / mute) → fx … → Out
///
/// A lane records a single clean input ([Lane.inputChannel]) and plays it back
/// through its own non-destructive effect chain to the outputs in
/// [Lane.outputMask]. Effects are reordered by dragging their handle and edited
/// in the panel below the path when one is selected. All edits are reported
/// through callbacks; this widget holds no state of its own.
class LaneStripView extends StatelessWidget {
  /// Creates a [LaneStripView] for [lane] at position [laneIndex].
  const LaneStripView({
    required this.laneIndex,
    required this.lane,
    required this.inputChannels,
    required this.outputChannels,
    required this.selectedEffect,
    required this.canRemove,
    required this.onInputChanged,
    required this.onOutputMaskChanged,
    required this.onVolumeChanged,
    required this.onMuteToggled,
    required this.onAddEffect,
    required this.onSelectEffect,
    required this.onMoveEffect,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemoveEffect,
    required this.onRemoveLane,
    this.excludedInputMask = 0,
    super.key,
  });

  /// The lane's index within its track (0-based).
  final int laneIndex;

  /// The lane whose routing + effects are drawn.
  final Lane lane;

  /// Hardware input/output channel counts (`0` when stopped).
  final int inputChannels;
  final int outputChannels;

  /// Loopback inputs, offered disabled and never selectable.
  final int excludedInputMask;

  /// The selected (expanded) effect's chain index, or null.
  final int? selectedEffect;

  /// Whether this lane can be removed (only the last lane of a multi-lane
  /// track, so the lane stack never empties).
  final bool canRemove;

  /// Sets the single hardware input this lane records (`-1` = none).
  final void Function(int inputChannel) onInputChanged;

  /// Toggles an output-routing connection (reports the new full mask).
  final void Function(int mask) onOutputMaskChanged;

  /// Playback volume / mute for the lane.
  final void Function(double volume) onVolumeChanged;
  final VoidCallback onMuteToggled;

  /// Appends a default effect to the lane's chain.
  final VoidCallback onAddEffect;

  /// Selects (expands) or deselects an effect card.
  final void Function(int? index) onSelectEffect;

  /// Moves a chain entry from index `from` to position `to`.
  final void Function(int from, int to) onMoveEffect;

  /// Edits the selected card.
  final void Function(int index, TrackEffectType type) onSetType;
  final void Function(int index, int param, double value) onSetParam;
  final void Function(int index) onRemoveEffect;

  /// Removes this lane (only offered when [canRemove]).
  final VoidCallback onRemoveLane;

  /// The input value the dropdown shows, falling back to `-1` (no input) when
  /// the stored channel is out of range for the current device.
  int get _inputValue =>
      lane.inputChannel >= 0 && lane.inputChannel < inputChannels
      ? lane.inputChannel
      : -1;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('lane_$laneIndex'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SetupSurfaceColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Lane ${laneIndex + 1}',
                style: const TextStyle(
                  color: SetupSurfaceColors.t1,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (canRemove)
                IconButton(
                  key: Key('lane_${laneIndex}_remove'),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  color: SetupSurfaceColors.t2,
                  tooltip: 'Remove lane',
                  onPressed: onRemoveLane,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _inputSelector(),
              _arrow(),
              _laneNode(),
              _arrow(),
              Expanded(child: _fxChain()),
              _arrow(),
              _outputSelector(),
            ],
          ),
          if (selectedEffect case final i?
              when i >= 0 && i < lane.effects.length) ...[
            const SizedBox(height: 10),
            _effectEditor(context, i, lane.effects[i]),
          ],
        ],
      ),
    );
  }

  Widget _arrow() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 6),
    child: Icon(
      Icons.arrow_right_alt,
      size: 18,
      color: SetupSurfaceColors.t3,
    ),
  );

  Widget _inputSelector() {
    return SizedBox(
      width: 104,
      child: DropdownButton<int>(
        key: Key('lane_${laneIndex}_input'),
        isExpanded: true,
        isDense: true,
        value: _inputValue,
        dropdownColor: SetupSurfaceColors.cardHi,
        style: const TextStyle(color: SetupSurfaceColors.t1, fontSize: 13),
        onChanged: (v) => onInputChanged(v ?? -1),
        items: [
          const DropdownMenuItem(value: -1, child: Text('No input')),
          for (var c = 0; c < inputChannels; c++)
            DropdownMenuItem(
              value: c,
              enabled: excludedInputMask & (1 << c) == 0,
              child: Text('In ${c + 1}'),
            ),
        ],
      ),
    );
  }

  Widget _laneNode() {
    return Container(
      width: 132,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SetupSurfaceColors.accent),
      ),
      child: Row(
        children: [
          IconButton(
            key: Key('lane_${laneIndex}_mute'),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            iconSize: 18,
            color: lane.muted
                ? SetupSurfaceColors.accent
                : SetupSurfaceColors.t2,
            tooltip: lane.muted ? 'Unmute lane' : 'Mute lane',
            icon: Icon(lane.muted ? Icons.volume_off : Icons.volume_up),
            onPressed: onMuteToggled,
          ),
          Expanded(
            child: SliderTheme(
              data: setupSliderTheme,
              child: Slider(
                key: Key('lane_${laneIndex}_vol'),
                value: lane.volume.clamp(0.0, 1.0),
                onChanged: onVolumeChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fxChain() {
    final effects = lane.effects;
    final full = effects.length >= kTrackEffectMax;
    return Row(
      children: [
        if (effects.isEmpty)
          const Expanded(
            child: Text(
              'No effects — recording stays dry',
              style: TextStyle(color: SetupSurfaceColors.t3, fontSize: 12),
            ),
          )
        else
          Expanded(
            child: SizedBox(
              height: 40,
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                itemCount: effects.length,
                onReorderItem: onMoveEffect,
                itemBuilder: (context, i) => _fxChip(
                  key: ValueKey('lane_${laneIndex}_fx_$i'),
                  index: i,
                  fx: effects[i],
                ),
              ),
            ),
          ),
        IconButton(
          key: Key('lane_${laneIndex}_fx_add'),
          padding: EdgeInsets.zero,
          iconSize: 22,
          color: SetupSurfaceColors.accent,
          tooltip: full ? 'Chain is full' : 'Add effect',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: full ? null : onAddEffect,
        ),
      ],
    );
  }

  Widget _fxChip({
    required Key key,
    required int index,
    required TrackEffect fx,
  }) {
    final selected = selectedEffect == index;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onSelectEffect(selected ? null : index),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: SetupSurfaceColors.cardHi,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? SetupSurfaceColors.accent
                    : SetupSurfaceColors.line,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReorderableDragStartListener(
                  key: Key('lane_${laneIndex}_fx_handle_$index'),
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
                const SizedBox(width: 4),
                Text(
                  fx.type.label,
                  style: const TextStyle(
                    color: SetupSurfaceColors.t1,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _outputSelector() {
    return SizedBox(
      width: 108,
      child: SetupChannelChips(
        keyPrefix: 'lane_${laneIndex}_output',
        channelCount: outputChannels > 0 ? outputChannels : 2,
        mask: lane.outputMask,
        onChanged: onOutputMaskChanged,
      ),
    );
  }

  /// The inline editor for the selected effect: type + parameter sliders.
  Widget _effectEditor(BuildContext context, int index, TrackEffect fx) {
    return Container(
      key: Key('lane_${laneIndex}_fx_editor'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.cardHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SetupSurfaceColors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<TrackEffectType>(
                  key: Key('lane_${laneIndex}_fx_type'),
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
                      onSetType(index, type);
                    }
                  },
                  items: [
                    for (final type in TrackEffectType.values)
                      if (type != TrackEffectType.none)
                        DropdownMenuItem(value: type, child: Text(type.label)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: Key('lane_${laneIndex}_fx_remove'),
                icon: const Icon(Icons.delete_outline, size: 18),
                color: SetupSurfaceColors.t2,
                tooltip: 'Remove effect',
                onPressed: () => onRemoveEffect(index),
              ),
            ],
          ),
          for (var p = 0; p < fx.type.paramLabels.length; p++)
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
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
                      data: setupSliderTheme,
                      child: Slider(
                        key: Key('lane_${laneIndex}_fx_param$p'),
                        value: fx.params[p].clamp(0.0, 1.0),
                        onChanged: (v) => onSetParam(index, p, v),
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
