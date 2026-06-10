import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/track_signal_flow_view.dart';
import 'package:settings_repository/settings_repository.dart';

/// Opens the per-track I/O routing page for [channel]: the signal-flow graph
/// (scoped to this one track) with its effects, plus its quantize override and
/// loop length. A full page (not a dialog) so there is room to see and edit.
///
/// Routing and effect changes are dispatched to the [LooperBloc] (which
/// forwards them to the engine and persists them). The caller's [context] must
/// be within the [LooperBloc] and [SettingsRepository] provider scope.
Future<void> showTrackRoutingDialog({
  required BuildContext context,
  required int channel,
}) {
  final bloc = context.read<LooperBloc>();
  final settings = context.read<SettingsRepository>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BlocProvider.value(
        value: bloc,
        child: _TrackRoutingPage(channel: channel, settings: settings),
      ),
    ),
  );
}

/// The per-track routing + effects page.
class _TrackRoutingPage extends StatelessWidget {
  const _TrackRoutingPage({required this.channel, required this.settings});

  final int channel;
  final SettingsRepository settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('trackRouting_page'),
      appBar: AppBar(title: Text('Track ${channel + 1} routing')),
      body: BlocBuilder<LooperBloc, LooperState>(
        builder: (context, state) {
          final current = channel < state.tracks.length
              ? state.tracks[channel]
              : Track(channel: channel);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Click a channel to connect it. Add effects with +, then '
                      'drag a card by its handle to reorder it or across the '
                      'track to switch before/after. Tap a card to edit it; '
                      'pinch or scroll to zoom.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    _TrackSignalFlowControl(
                      channel: channel,
                      settings: settings,
                      track: current,
                      inputChannels: state.status.inputChannels,
                      outputChannels: state.status.outputChannels,
                      excludedInputMask: state.status.excludedInputMask,
                      height: 400,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Quantize recording',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    _TrackQuantizeControl(channel: channel, settings: settings),
                    const SizedBox(height: 24),
                    Text(
                      'Loop length',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    _TrackMultipleControl(channel: channel, settings: settings),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
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
    required this.height,
  });

  final int channel;
  final SettingsRepository settings;
  final Track track;
  final int inputChannels;
  final int outputChannels;
  final int excludedInputMask;
  final double height;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TrackSignalFlowView(
          track: widget.track,
          inputChannels: widget.inputChannels,
          outputChannels: widget.outputChannels,
          excludedInputMask: widget.excludedInputMask,
          effects: _chain,
          selectedEffect: _selected,
          onInputMaskChanged: (mask) =>
              _bloc.add(LooperInputMaskChanged(widget.channel, mask)),
          onOutputMaskChanged: (mask) =>
              _bloc.add(LooperOutputMaskChanged(widget.channel, mask)),
          onAddEffect: _add,
          onMoveEffect: _move,
          onSelectEffect: (i) => setState(() => _selected = i),
          onSetType: _setType,
          onSetParam: _setParam,
          onRemoveEffect: _removeAt,
          height: widget.height,
        ),
        const SizedBox(height: 8),
        Text(
          'To hear before-track effects live, set monitoring to follow this '
          'track.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
