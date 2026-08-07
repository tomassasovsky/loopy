import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/theme/theme.dart';

/// Exactly what the Click face draws. See `TempoLoopTab` for why this is a
/// record fed to `context.select` rather than the whole `TransportState`.
typedef _ClickValues = ({
  ClickMode clickMode,
  int clickMask,
  double clickVolume,
  int outputs,
});

_ClickValues _clickValues(LooperState state) => (
  clickMode: state.transport.clickMode,
  clickMask: state.transport.clickMask,
  clickVolume: state.transport.clickVolume,
  // The engine reports 0 outputs before the device is open; 2 is what every
  // other surface assumes then, and a click with nowhere to go is not a
  // useful thing to draw.
  outputs: state.status.outputChannels > 0 ? state.status.outputChannels : 2,
);

/// Which row of the Click face has its chooser open. See `TempoLoopTab` for
/// why at most one.
enum _ClickRow {
  /// When the click is audible.
  when,

  /// Which hardware outputs it sounds on.
  output,
}

/// The Click tab of the Loop domain: when the click plays, where it goes, and
/// how loud.
///
/// Live values off [LooperBloc]'s `TransportState`, writes through
/// [TempoCubit] — the same split every Loop face keeps, and for the reason
/// spelled out on `TempoLoopTab`.
class ClickLoopTab extends StatefulWidget {
  /// Creates a [ClickLoopTab].
  const ClickLoopTab({super.key});

  @override
  State<ClickLoopTab> createState() => _ClickLoopTabState();
}

class _ClickLoopTabState extends State<ClickLoopTab> {
  _ClickRow? _open;

  void _toggle(_ClickRow row) =>
      setState(() => _open = _open == row ? null : row);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final transport = context.select<LooperBloc, _ClickValues>(
      (bloc) => _clickValues(bloc.state),
    );
    final cubit = context.read<TempoCubit>();
    final outputs = transport.outputs;

    return KeyedSubtree(
      key: const Key('loop_click_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: kConsoleGroupGap),
            ConsoleGroupLabel(l10n.loopClickGroup),
            const SizedBox(height: kConsoleLabelGap),
            ConsoleCard(
              children: [
                ..._whenRow(context, transport, cubit),
                ..._outputRow(context, transport, cubit, outputs),
              ],
            ),
            const SizedBox(height: kConsoleBlockGap),
            _volumeCard(context, transport, cubit),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ when

  List<Widget> _whenRow(
    BuildContext context,
    _ClickValues transport,
    TempoCubit cubit,
  ) {
    final l10n = context.l10n;
    final open = _open == _ClickRow.when;
    final labels = clickModeLabels(l10n);
    return [
      ConsoleRow(
        key: const Key('loop_click_when_row'),
        title: l10n.loopClickWhenRow,
        state: labels[transport.clickMode],
        expanded: open,
        fill: open ? context.surface.control : null,
        onTap: () => _toggle(_ClickRow.when),
      ),
      ConsoleChooser(
        key: const Key('loop_click_when_slot'),
        open: open,
        children: [
          Padding(
            padding: ConsoleChooser.gridInset,
            child: ConsoleChipGrid<ClickMode>(
              selected: {transport.clickMode},
              options: [
                for (final mode in ClickMode.values)
                  ConsoleSegment(
                    value: mode,
                    label: labels[mode]!,
                    optionKey: Key('loop_click_when_${mode.name}'),
                  ),
              ],
              onTap: (mode) {
                setState(() => _open = null);
                unawaited(cubit.setClickMode(mode));
              },
            ),
          ),
        ],
      ),
    ];
  }

  // ---------------------------------------------------------------- output

  /// How many outputs the readout names before it starts counting them.
  static const int _summaryLimit = 3;

  /// The click's output routing.
  ///
  /// **The one chooser here that is not pick-one**: the click sounds on a
  /// bitmask of hardware outputs, so several checks can be lit at once and a
  /// tap toggles one bit rather than replacing the answer. It stays open
  /// across taps for the same reason — there is no single pick that ends the
  /// question.
  List<Widget> _outputRow(
    BuildContext context,
    _ClickValues transport,
    TempoCubit cubit,
    int outputs,
  ) {
    final l10n = context.l10n;
    final open = _open == _ClickRow.output;
    final mask = transport.clickMask;
    final all = (1 << outputs) - 1;
    final chosen = [
      for (var i = 0; i < outputs; i++)
        if (mask & (1 << i) != 0) i,
    ];
    // Named up to [_summaryLimit], counted past it: an 18-out interface with
    // nine boxes ticked would otherwise put a sentence in the readout column
    // and push the row's own marker off the card.
    final summary = switch (chosen.length) {
      0 => l10n.loopClickOutputNone,
      _ when mask & all == all => l10n.loopClickOutputAll,
      > _summaryLimit => l10n.loopClickOutputCount(chosen.length),
      _ => chosen.map((i) => l10n.outputChannelLabel(i + 1)).join(' · '),
    };
    return [
      ConsoleRow(
        key: const Key('loop_click_output_row'),
        title: l10n.loopClickOutputRow,
        state: summary,
        expanded: open,
        showDivider: false,
        fill: open ? context.surface.control : null,
        onTap: () => _toggle(_ClickRow.output),
      ),
      ConsoleChooser(
        key: const Key('loop_click_output_slot'),
        open: open,
        children: [
          Padding(
            padding: ConsoleChooser.gridInset,
            child: ConsoleChipGrid<int>(
              // A set, not a single value: this is the bitmask case the grid
              // exists to serve, and several cells are lit at once.
              selected: chosen.toSet(),
              options: [
                for (var i = 0; i < outputs; i++)
                  ConsoleSegment(
                    value: i,
                    label: l10n.outputChannelLabel(i + 1),
                    optionKey: Key('loop_click_output_$i'),
                  ),
              ],
              // Toggles one bit and leaves the grid open: no single tap
              // answers this question, so nothing here closes it.
              onTap: (i) => unawaited(cubit.setClickOutput(mask ^ (1 << i))),
            ),
          ),
        ],
      ),
    ];
  }

  // ---------------------------------------------------------------- volume

  /// The click's own level, over the whole gain stage.
  ///
  /// The bar's `0..1` travel maps onto `0..`[kMaxClickGain] — the engine's
  /// own ceiling, and the range the Settings slider already has. The readout
  /// stays percent-of-unity like the rest of the app, which puts a normal
  /// click at half the bar and keeps the headroom reachable from the console
  /// instead of only from Settings. Double-tap snaps back to unity.
  Widget _volumeCard(
    BuildContext context,
    _ClickValues transport,
    TempoCubit cubit,
  ) {
    final l10n = context.l10n;
    final volume = transport.clickVolume.clamp(0.0, kMaxClickGain);
    return ConsoleCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(18),
          child: ConsoleValueBar(
            key: const Key('loop_click_volume'),
            label: l10n.loopClickVolumeLabel,
            value: volume / kMaxClickGain,
            resetValue: 1 / kMaxClickGain,
            readout: l10n.loopClickVolumeReadout((volume * 100).round()),
            semanticLabel: l10n.a11yLoopClickVolume,
            onChanged: (value) =>
                unawaited(cubit.setClickVolume(value * kMaxClickGain)),
          ),
        ),
      ],
    );
  }
}
