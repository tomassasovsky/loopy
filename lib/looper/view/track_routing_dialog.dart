import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/routing_graph_view.dart';
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
          width: 460,
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
                      'Click an input or output to connect or disconnect it.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    RoutingGraphView(
                      tracks: [current],
                      inputChannels: state.status.inputChannels,
                      outputChannels: state.status.outputChannels,
                      excludedInputMask: state.status.excludedInputMask,
                      initialArmed: 0,
                      onInputMaskChanged: (ch, mask) =>
                          bloc.add(LooperInputMaskChanged(ch, mask)),
                      onOutputMaskChanged: (ch, mask) =>
                          bloc.add(LooperOutputMaskChanged(ch, mask)),
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
                    const SizedBox(height: 16),
                    Text(
                      'Effects',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    _TrackEffectsControl(channel: channel, settings: settings),
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

/// The per-track effects chain: [kTrackEffectSlots] insert slots, each a type
/// selector plus a slider per parameter the chosen type exposes. Loads the
/// saved chain from [settings] and dispatches changes through the [LooperBloc].
class _TrackEffectsControl extends StatefulWidget {
  const _TrackEffectsControl({required this.channel, required this.settings});

  final int channel;
  final SettingsRepository settings;

  @override
  State<_TrackEffectsControl> createState() => _TrackEffectsControlState();
}

class _TrackEffectsControlState extends State<_TrackEffectsControl> {
  /// Per-slot effect type and its [kTrackEffectParams] parameter values.
  final List<TrackEffectType> _types = List.filled(
    kTrackEffectSlots,
    TrackEffectType.none,
  );
  final List<List<double>> _params = List.generate(
    kTrackEffectSlots,
    (_) => List<double>.filled(kTrackEffectParams, 0),
    growable: false,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final types = List<TrackEffectType>.filled(
      kTrackEffectSlots,
      TrackEffectType.none,
    );
    final params = List.generate(
      kTrackEffectSlots,
      (_) => List<double>.filled(kTrackEffectParams, 0),
      growable: false,
    );
    for (var slot = 0; slot < kTrackEffectSlots; slot++) {
      final code = await widget.settings.loadTrackFxType(widget.channel, slot);
      final type = code == null
          ? TrackEffectType.none
          : TrackEffectType.fromCode(code);
      types[slot] = type;
      for (var i = 0; i < kTrackEffectParams; i++) {
        final saved = await widget.settings.loadTrackFxParam(
          widget.channel,
          slot,
          i,
        );
        params[slot][i] = saved ?? type.defaultParams[i];
      }
    }
    if (mounted) {
      setState(() {
        for (var slot = 0; slot < kTrackEffectSlots; slot++) {
          _types[slot] = types[slot];
          _params[slot] = params[slot];
        }
      });
    }
  }

  void _setType(int slot, TrackEffectType type) {
    setState(() {
      _types[slot] = type;
      // Mirror the engine's seeded defaults for the new type so the sliders
      // start where the engine does (parameters are not dispatched here; the
      // engine seeds them when the type changes).
      _params[slot] = List<double>.from(type.defaultParams);
    });
    context.read<LooperBloc>().add(
      LooperTrackFxChanged(widget.channel, slot, type),
    );
  }

  void _setParam(int slot, int index, double value) {
    setState(() => _params[slot][index] = value);
    context.read<LooperBloc>().add(
      LooperTrackFxParamChanged(widget.channel, slot, index, value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var slot = 0; slot < kTrackEffectSlots; slot++) ...[
          if (slot > 0) const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 64,
                child: Text('Slot ${slot + 1}', style: textTheme.bodyMedium),
              ),
              Expanded(
                child: DropdownButton<TrackEffectType>(
                  key: Key('trackRouting_fx${slot}_type'),
                  isExpanded: true,
                  value: _types[slot],
                  onChanged: (type) {
                    if (type != null) _setType(slot, type);
                  },
                  items: [
                    for (final type in TrackEffectType.values)
                      DropdownMenuItem(
                        value: type,
                        child: Text(type.label),
                      ),
                  ],
                ),
              ),
            ],
          ),
          for (var i = 0; i < _types[slot].paramLabels.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 80,
                    child: Text(
                      _types[slot].paramLabels[i],
                      style: textTheme.bodySmall,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      key: Key('trackRouting_fx${slot}_param$i'),
                      value: _params[slot][i].clamp(0.0, 1.0),
                      onChanged: (v) => _setParam(slot, i, v),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
