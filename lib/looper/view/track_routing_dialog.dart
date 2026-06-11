import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/looper/view/lane_graph_view.dart';
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
  final bigPicture = context.read<BigPictureCubit>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BlocProvider.value(
        value: bloc,
        child: _TrackRoutingPage(
          channel: channel,
          settings: settings,
          bigPicture: bigPicture,
        ),
      ),
    ),
  );
}

/// The per-track routing + effects page.
class _TrackRoutingPage extends StatelessWidget {
  const _TrackRoutingPage({
    required this.channel,
    required this.settings,
    required this.bigPicture,
  });

  final int channel;
  final SettingsRepository settings;
  final BigPictureCubit bigPicture;

  @override
  Widget build(BuildContext context) {
    final trackName = bigPicture.state.names[channel];

    return Scaffold(
      key: const Key('trackRouting_page'),
      appBar: AppBar(
        title: Text('$trackName routing'),
        actions: [
          IconButton(
            key: const Key('trackRouting_settings_button'),
            icon: const Icon(Icons.tune),
            tooltip: 'Track settings',
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      // The stacked per-lane signal-flow strips fill the whole page.
      body: BlocBuilder<LooperBloc, LooperState>(
        builder: (context, state) {
          final current = channel < state.tracks.length
              ? state.tracks[channel]
              : Track(channel: channel);
          return _LaneList(
            channel: channel,
            settings: settings,
            track: current,
            inputChannels: state.status.inputChannels,
            outputChannels: state.status.outputChannels,
            excludedInputMask: state.status.excludedInputMask,
          );
        },
      ),
    );
  }

  /// Opens the secondary settings (quantize + loop length) for this track.
  void _openSettings(BuildContext context) {
    final bloc = context.read<LooperBloc>();
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => BlocProvider.value(
          value: bloc,
          child: AlertDialog(
            key: const Key('trackRouting_settings_dialog'),
            title: Text('Track ${channel + 1} settings'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quantize recording',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _TrackQuantizeControl(channel: channel, settings: settings),
                  const SizedBox(height: 20),
                  Text(
                    'Loop length',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _TrackMultipleControl(channel: channel, settings: settings),
                  const SizedBox(height: 16),
                  Text(
                    'Track effects color playback only. To hear effects live '
                    'on an input, enable its monitor in audio settings.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
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

/// The per-track routing + effects editor: a [LaneGraphView] wiring inputs ▸
/// lanes ▸ outputs in one canvas. A track may add or remove lanes, and each
/// lane records its own clean input and plays back through its own
/// non-destructive chain.
///
/// Routing, mix, and lane-count edits are dispatched to the [LooperBloc]; the
/// per-lane effect chains are held locally for snappy editing (seeded from
/// [settings]) and mirrored to the engine as [LooperLaneEffectsChanged] /
/// [LooperLaneEffectParamChanged] events.
class _LaneList extends StatefulWidget {
  const _LaneList({
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
  State<_LaneList> createState() => _LaneListState();
}

class _LaneListState extends State<_LaneList> {
  /// Active lane count (seeded from settings, edited by add/remove).
  int _laneCount = 1;

  /// Per-lane effect chains in engine order; every entry colors playback.
  ///
  /// These are the working copy for snappy editing: routing / mix (input,
  /// output, volume, mute) come live from the bloc state via [_laneFor], but
  /// the effect chain is held here and mirrored to the engine through
  /// [LooperLaneEffectsChanged] / [LooperLaneEffectParamChanged]. [_laneFor]
  /// deliberately never reads the state lane's `effects`, so these two keyed
  /// sources never compete: this map owns effects, the state owns the rest.
  final Map<int, List<TrackEffect>> _chains = {};

  /// The currently expanded effect card, as `(lane, index)`, or null.
  ({int lane, int index})? _selected;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final count = (await widget.settings.loadLaneCount(widget.channel)).clamp(
      1,
      kMaxLanes,
    );
    final chains = <int, List<TrackEffect>>{};
    for (var l = 0; l < count; l++) {
      chains[l] = decodeTrackEffects(
        await widget.settings.loadLaneEffects(widget.channel, l),
      );
    }
    if (mounted) {
      setState(() {
        _laneCount = count;
        _chains
          ..clear()
          ..addAll(chains);
      });
    }
  }

  LooperBloc get _bloc => context.read<LooperBloc>();

  List<TrackEffect> _chainOf(int lane) => _chains[lane] ?? const [];

  /// The lane handed to the strip: routing / mix come live from the bloc state,
  /// the effect chain from the local working copy.
  Lane _laneFor(int lane) {
    final lanes = widget.track.lanes;
    final base = lane < lanes.length ? lanes[lane] : const Lane();
    return Lane(
      inputChannel: base.inputChannel,
      outputMask: base.outputMask,
      volume: base.volume,
      muted: base.muted,
      effects: _chainOf(lane),
    );
  }

  void _addLane() {
    if (_laneCount >= kMaxLanes) return;
    setState(() {
      _chains[_laneCount] = [];
      _laneCount += 1;
    });
    _bloc.add(LooperLaneCountChanged(widget.channel, _laneCount));
  }

  /// Removes [lane] and shifts every later lane up one slot: each subsequent
  /// lane's routing, mix, and effect chain is reapplied onto the previous
  /// index, then the count drops by one.
  ///
  /// This moves the lane *configuration*; a recorded lane's audio buffer is not
  /// moved (that needs engine-side compaction — a follow-up). The common case —
  /// reorganising lanes while configuring routing — behaves as expected.
  void _removeLane(int lane) {
    if (_laneCount <= 1 || lane < 0 || lane >= _laneCount) return;
    final channel = widget.channel;
    final lanes = widget.track.lanes;
    Lane stateLane(int j) => j < lanes.length ? lanes[j] : const Lane();
    for (var j = lane; j < _laneCount - 1; j++) {
      final src = stateLane(j + 1);
      _bloc
        ..add(LooperLaneInputChanged(channel, j, src.inputChannel))
        ..add(LooperLaneOutputChanged(channel, j, src.outputMask))
        ..add(LooperLaneVolumeChanged(channel, j, src.volume));
      // Mute has no absolute setter; toggle only when the value must change.
      if (stateLane(j).muted != src.muted) {
        _bloc.add(LooperLaneMuteToggled(channel, j));
      }
      _bloc.add(
        LooperLaneEffectsChanged(
          channel,
          j,
          List<TrackEffect>.of(_chainOf(j + 1)),
        ),
      );
    }
    setState(() {
      for (var j = lane; j < _laneCount - 1; j++) {
        _chains[j] = List<TrackEffect>.of(_chainOf(j + 1));
      }
      _chains.remove(_laneCount - 1);
      _laneCount -= 1;
      _selected = null;
    });
    _bloc.add(LooperLaneCountChanged(channel, _laneCount));
  }

  void _pushChain(int lane) {
    _bloc.add(
      LooperLaneEffectsChanged(
        widget.channel,
        lane,
        List<TrackEffect>.of(_chainOf(lane)),
      ),
    );
  }

  void _addEffect(int lane) {
    final chain = _chainOf(lane);
    if (chain.length >= kTrackEffectMax) return;
    setState(() {
      _chains[lane] = [...chain, TrackEffect(type: TrackEffectType.drive)];
      _selected = (lane: lane, index: chain.length);
    });
    _pushChain(lane);
  }

  void _removeEffect(int lane, int index) {
    final chain = _chainOf(lane);
    setState(() {
      _chains[lane] = [...chain]..removeAt(index);
      _selected = null;
    });
    _pushChain(lane);
  }

  void _setType(int lane, int index, TrackEffectType type) {
    final chain = _chainOf(lane);
    setState(() {
      _chains[lane] = [...chain]
        ..[index] = chain[index].copyWith(
          type: type,
          params: type.defaultParams,
        );
    });
    _pushChain(lane);
  }

  void _setParam(int lane, int index, int param, double value) {
    final chain = _chainOf(lane);
    setState(() {
      final params = List<double>.of(chain[index].params)..[param] = value;
      _chains[lane] = [...chain]
        ..[index] = chain[index].copyWith(params: params);
    });
    _bloc.add(
      LooperLaneEffectParamChanged(widget.channel, lane, index, param, value),
    );
  }

  /// Drag-and-drop: move lane [lane]'s chain entry [from] to position [to].
  void _move(int lane, int from, int to) {
    final chain = _chainOf(lane);
    if (from < 0 || from >= chain.length) return;
    final target = to.clamp(0, chain.length - 1);
    if (from == target) return;
    final next = [...chain];
    next.insert(target, next.removeAt(from));
    setState(() {
      _chains[lane] = next;
      _selected = (lane: lane, index: target);
    });
    _pushChain(lane);
  }

  void _select(int lane, int? index) {
    setState(
      () => _selected = index == null ? null : (lane: lane, index: index),
    );
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    return LaneGraphView(
      key: const Key('trackRouting_laneGraph'),
      lanes: [for (var l = 0; l < _laneCount; l++) _laneFor(l)],
      inputChannels: widget.inputChannels,
      outputChannels: widget.outputChannels,
      excludedInputMask: widget.excludedInputMask,
      selectedEffect: _selected,
      onInputChanged: (l, c) =>
          _bloc.add(LooperLaneInputChanged(channel, l, c)),
      onOutputMaskChanged: (l, m) =>
          _bloc.add(LooperLaneOutputChanged(channel, l, m)),
      onVolumeChanged: (l, v) =>
          _bloc.add(LooperLaneVolumeChanged(channel, l, v)),
      onMuteToggled: (l) => _bloc.add(LooperLaneMuteToggled(channel, l)),
      onAddEffect: _addEffect,
      onSelectEffect: _select,
      onMoveEffect: _move,
      onSetType: _setType,
      onSetParam: _setParam,
      onRemoveEffect: _removeEffect,
      onAddLane: _addLane,
      onRemoveLane: _removeLane,
    );
  }
}
