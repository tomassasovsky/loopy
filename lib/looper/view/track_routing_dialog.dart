import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/track_signal_flow_view.dart';
import 'package:settings_repository/settings_repository.dart';

/// Opens the per-track I/O routing dialog for [channel]: the signal-flow graph
/// (scoped to this one track) plus its quantize override.
///
/// Routing and quantize changes are dispatched to the [LooperBloc] (which
/// forwards them to the engine and persists them). The caller's [context] must
/// be within the [LooperBloc] and [SettingsRepository] provider scope.
Future<void> showTrackRoutingDialog({
  required BuildContext context,
  required int channel,
}) {
  final bloc = context.read<LooperBloc>();
  final settings = context.read<SettingsRepository>();
  return showDialog<void>(
    context: context,
    builder: (_) => BlocProvider.value(
      value: bloc,
      child: AlertDialog(
        key: const Key('trackRouting_dialog'),
        title: Text('Track ${channel + 1} routing'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: BlocBuilder<LooperBloc, LooperState>(
              builder: (context, state) {
                final current = channel < state.tracks.length
                    ? state.tracks[channel]
                    : Track(channel: channel);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Click a channel to connect it. Add effects with +, then '
                      'drag a card to reorder it or across the track to switch '
                      'before/after. Tap a card to edit it.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    _TrackSignalFlowControl(
                      channel: channel,
                      settings: settings,
                      track: current,
                      inputChannels: state.status.inputChannels,
                      outputChannels: state.status.outputChannels,
                      excludedInputMask: state.status.excludedInputMask,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Quantize recording',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    _TrackQuantizeControl(channel: channel, settings: settings),
                    const SizedBox(height: 16),
                    Text(
                      'Loop length',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    _TrackMultipleControl(channel: channel, settings: settings),
                  ],
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('trackRouting_done_button'),
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}

/// A tri-state quantize selector for one track: Default (inherit the global
/// setting), On, or Off. Loads the current override from [settings] and
/// dispatches changes through the [LooperBloc].
class _TrackQuantizeControl extends StatefulWidget {
  const _TrackQuantizeControl({required this.channel, required this.settings});

  final int channel;
  final SettingsRepository settings;

  @override
  State<_TrackQuantizeControl> createState() => _TrackQuantizeControlState();
}

class _TrackQuantizeControlState extends State<_TrackQuantizeControl> {
  bool? _override;
  bool _globalDefault = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final value = await widget.settings.loadTrackQuantize(widget.channel);
    final global = await widget.settings.loadQuantize();
    if (mounted) {
      setState(() {
        _override = value;
        _globalDefault = global;
      });
    }
  }

  void _set(bool? value) {
    setState(() => _override = value);
    context.read<LooperBloc>().add(
      LooperTrackQuantizeChanged(widget.channel, enabled: value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        ChoiceChip(
          key: const Key('trackRouting_quantize_default'),
          label: Text('Default (${_globalDefault ? 'On' : 'Off'})'),
          selected: _override == null,
          onSelected: (_) => _set(null),
        ),
        ChoiceChip(
          key: const Key('trackRouting_quantize_on'),
          label: const Text('On'),
          selected: _override == true,
          onSelected: (_) => _set(true),
        ),
        ChoiceChip(
          key: const Key('trackRouting_quantize_off'),
          label: const Text('Off'),
          selected: _override == false,
          onSelected: (_) => _set(false),
        ),
      ],
    );
  }
}

/// A loop-length selector for one track: Auto (round up on stop) or a fixed
/// number of base loops (×1 / ×2 / ×3). Loads the current value from [settings]
/// and dispatches changes through the [LooperBloc].
class _TrackMultipleControl extends StatefulWidget {
  const _TrackMultipleControl({required this.channel, required this.settings});

  final int channel;
  final SettingsRepository settings;

  @override
  State<_TrackMultipleControl> createState() => _TrackMultipleControlState();
}

class _TrackMultipleControlState extends State<_TrackMultipleControl> {
  /// 0 = inherit the global default; 1/2/3 = fixed.
  int _multiple = 0;
  int _globalDefault = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final value = await widget.settings.loadTrackMultiple(widget.channel);
    final global = await widget.settings.loadDefaultMultiple();
    if (mounted) {
      setState(() {
        _multiple = value;
        _globalDefault = global;
      });
    }
  }

  void _set(int value) {
    setState(() => _multiple = value);
    context.read<LooperBloc>().add(
      LooperTrackMultipleChanged(widget.channel, value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final globalLabel = _globalDefault == 0 ? 'Auto' : '×$_globalDefault';
    return Wrap(
      spacing: 8,
      children: [
        ChoiceChip(
          key: const Key('trackRouting_multiple_auto'),
          label: Text('Default ($globalLabel)'),
          selected: _multiple == 0,
          onSelected: (_) => _set(0),
        ),
        for (final k in const [1, 2, 3])
          ChoiceChip(
            key: Key('trackRouting_multiple_$k'),
            label: Text('×$k'),
            selected: _multiple == k,
            onSelected: (_) => _set(k),
          ),
      ],
    );
  }
}

/// The per-track effects chain, drawn as a signal-flow strip of cards:
///
///   In ▸ [before-the-track effects] ▸ Track ▸ [after-the-track effects] ▸ Out
///
/// "Before" effects are printed into the recording; "after" effects process
/// playback (non-destructive). Cards are added per lane, reordered within a
/// lane, moved across the track (changing the stage), and edited (type +
/// parameter sliders) by selecting one. Loads the saved chain from [settings]
/// and dispatches changes through the [LooperBloc]: structural edits as a whole
/// [LooperTrackEffectsChanged], live slider tweaks as a granular
/// [LooperTrackEffectParamChanged].
/// The integrated single-track signal-flow graph: channel routing plus the
/// effects chain as draggable cards on the path. Loads the saved chain from
/// [settings], dispatches routing + structural changes as [LooperBloc] events,
/// and shows an inline editor for the selected card.
class _TrackSignalFlowControl extends StatefulWidget {
  const _TrackSignalFlowControl({
    required this.channel,
    required this.settings,
    required this.track,
    required this.inputChannels,
    required this.outputChannels,
    required this.excludedInputMask,
  });

  final int channel;
  final SettingsRepository settings;
  final Track track;
  final int inputChannels;
  final int outputChannels;
  final int excludedInputMask;

  @override
  State<_TrackSignalFlowControl> createState() =>
      _TrackSignalFlowControlState();
}

class _TrackSignalFlowControlState extends State<_TrackSignalFlowControl> {
  /// The chain in engine order. Pre-stage entries process the input; post-stage
  /// entries process playback. The split into lanes is derived for display.
  List<TrackEffect> _chain = [];

  /// The index in [_chain] of the card being edited, or null.
  int? _selected;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final encoded = await widget.settings.loadTrackEffects(widget.channel);
    final chain = decodeTrackEffects(encoded);
    if (mounted) setState(() => _chain = chain);
  }

  LooperBloc get _bloc => context.read<LooperBloc>();

  void _pushStructural() {
    _bloc.add(
      LooperTrackEffectsChanged(widget.channel, List<TrackEffect>.of(_chain)),
    );
  }

  void _add(TrackEffectStage stage) {
    if (_chain.length >= kTrackEffectMax) return;
    setState(() {
      _chain = [
        ..._chain,
        TrackEffect(type: TrackEffectType.drive, stage: stage),
      ];
      _selected = _chain.length - 1;
    });
    _pushStructural();
  }

  void _removeAt(int index) {
    setState(() {
      _chain = [..._chain]..removeAt(index);
      _selected = null;
    });
    _pushStructural();
  }

  void _setType(int index, TrackEffectType type) {
    setState(() {
      _chain = [..._chain]
        ..[index] = _chain[index].copyWith(
          type: type,
          params: type.defaultParams,
        );
    });
    _pushStructural();
  }

  void _setStage(int index, TrackEffectStage stage) {
    if (_chain[index].stage == stage) return;
    setState(() {
      _chain = [..._chain]..[index] = _chain[index].copyWith(stage: stage);
    });
    _pushStructural();
  }

  void _setParam(int index, int param, double value) {
    setState(() {
      final params = List<double>.of(_chain[index].params)..[param] = value;
      _chain = [..._chain]..[index] = _chain[index].copyWith(params: params);
    });
    _bloc.add(
      LooperTrackEffectParamChanged(widget.channel, index, param, value),
    );
  }

  /// Drag-and-drop: move chain entry [from] to lane [stage] at position [toPos]
  /// within that lane (reorder, or restage by dropping across the track).
  void _move(int from, TrackEffectStage stage, int toPos) {
    final moved = _chain[from];
    final without = [..._chain]..removeAt(from);
    final laneFlat = [
      for (var i = 0; i < without.length; i++)
        if (without[i].stage == stage) i,
    ];
    final insert = toPos >= laneFlat.length
        ? (laneFlat.isEmpty ? without.length : laneFlat.last + 1)
        : laneFlat[toPos];
    setState(() {
      _chain = without..insert(insert, moved.copyWith(stage: stage));
      _selected = insert;
    });
    _pushStructural();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TrackSignalFlowView(
          track: widget.track,
          inputChannels: widget.inputChannels,
          outputChannels: widget.outputChannels,
          excludedInputMask: widget.excludedInputMask,
          effects: _chain,
          onInputMaskChanged: (mask) =>
              _bloc.add(LooperInputMaskChanged(widget.channel, mask)),
          onOutputMaskChanged: (mask) =>
              _bloc.add(LooperOutputMaskChanged(widget.channel, mask)),
          onAddEffect: _add,
          onMoveEffect: _move,
          selectedEffect: selected,
          onSelectEffect: (i) => setState(() => _selected = i),
        ),
        if (selected != null && selected < _chain.length) ...[
          const SizedBox(height: 12),
          _editor(selected, _chain[selected]),
        ] else ...[
          const SizedBox(height: 8),
          Text(
            'Add an effect before the track to record through it, or after the '
            'track to process playback. To hear before-track effects live, set '
            'monitoring to follow this track.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _editor(int index, TrackEffect fx) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const Key('trackRouting_fx_editor'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<TrackEffectType>(
                  key: const Key('trackRouting_fx_type'),
                  isExpanded: true,
                  value: fx.type,
                  onChanged: (type) {
                    if (type != null && type != TrackEffectType.none) {
                      _setType(index, type);
                    }
                  },
                  items: [
                    for (final type in TrackEffectType.values)
                      if (type != TrackEffectType.none)
                        DropdownMenuItem(value: type, child: Text(type.label)),
                  ],
                ),
              ),
              IconButton(
                key: const Key('trackRouting_fx_remove'),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove effect',
                onPressed: () => _removeAt(index),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Drag a card across the track to restage; this is the same action
          // for keyboard/non-drag use.
          SegmentedButton<TrackEffectStage>(
            segments: const [
              ButtonSegment(
                value: TrackEffectStage.pre,
                label: Text('Before track'),
                icon: Icon(Icons.fiber_manual_record, size: 14),
              ),
              ButtonSegment(
                value: TrackEffectStage.post,
                label: Text('After track'),
                icon: Icon(Icons.volume_up, size: 14),
              ),
            ],
            selected: {fx.stage},
            onSelectionChanged: (s) => _setStage(index, s.first),
          ),
          for (var p = 0; p < fx.type.paramLabels.length; p++)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 80,
                    child: Text(
                      fx.type.paramLabels[p],
                      style: textTheme.bodySmall,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      key: Key('trackRouting_fx_param$p'),
                      value: fx.params[p].clamp(0.0, 1.0),
                      onChanged: (v) => _setParam(index, p, v),
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
