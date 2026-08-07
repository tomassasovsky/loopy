import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/loop/tempo_keypad_sheet.dart';
import 'package:segno/theme/theme.dart';

/// Which row of the Tempo face has its chooser open. At most one — an
/// accordion across the whole face, not one per card: two drawers open at once
/// would push the second past the sheet the face has to fit in.
enum _TempoRow {
  /// The 17 valid time signatures.
  signature,

  /// Auto, or a fixed multiple of the base loop.
  length,

  /// The musical quantization granularity.
  quantise,

  /// Count-in measures.
  countIn,
}

/// The Tempo tab of the Loop domain: what the grid is, and what the loop does
/// about it.
///
/// **Live values come off the transport, writes go through the cubits.** Every
/// readout here is [LooperBloc]'s `TransportState` — the tempo especially,
/// because [TempoCubit] holds *explicitly configured intent* (`0` until
/// someone types one) and never moves for a tapped or loop-derived tempo.
/// Reading the cubit to display "the current tempo" is a bug that only shows
/// up for the inputs the user cannot type.
///
/// The one exception is the loop length, and it is an exception because the
/// engine projects no global default onto the transport: `RecordOptionsCubit`
/// is the only place that value exists.
class TempoLoopTab extends StatefulWidget {
  /// Creates a [TempoLoopTab].
  const TempoLoopTab({super.key});

  @override
  State<TempoLoopTab> createState() => _TempoLoopTabState();
}

class _TempoLoopTabState extends State<TempoLoopTab> {
  _TempoRow? _open;

  void _toggle(_TempoRow row) =>
      setState(() => _open = _open == row ? null : row);

  /// Closes the drawer and applies [write]. Every pick does both: a chooser
  /// left open after its answer arrived is a list of alternatives to a
  /// question nobody is still asking.
  void _pick(VoidCallback write) {
    setState(() => _open = null);
    write();
  }

  /// A chooser whose options are bare tokens, laid out as a grid.
  ///
  /// Every option on this face is one — `3/4`, `x2`, `1/8`, `1 bar` — so all
  /// four choosers take the grid. See [ConsoleChipGrid] for why a token in a
  /// 70px row is the wrong shape.
  Widget _grid<T>({
    required String slot,
    required bool open,
    required List<ConsoleSegment<T>> options,
    required T current,
    required ValueChanged<T> onPick,
  }) => ConsoleChooser(
    key: Key(slot),
    open: open,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          ConsoleRow.indentedInset,
          kConsoleBlockGap,
          kConsoleRowInset,
          kConsoleBlockGap,
        ),
        child: ConsoleChipGrid<T>(
          options: options,
          selected: {current},
          onTap: (value) => _pick(() => onPick(value)),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final transport = context.watch<LooperBloc>().state.transport;
    final multiple = context.watch<RecordOptionsCubit>().state.defaultMultiple;
    final tempo = context.read<TempoCubit>();
    final options = context.read<RecordOptionsCubit>();

    return KeyedSubtree(
      key: const Key('loop_tempo_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: kConsoleGroupGap),
            ConsoleGroupLabel(l10n.loopTempoGroup),
            const SizedBox(height: kConsoleLabelGap),
            ConsoleCard(
              children: [
                _tempoRow(context, transport),
                ..._signatureRow(context, transport, tempo),
                ..._lengthRow(context, multiple, options),
                ..._quantiseRow(context, transport, tempo),
                ..._countInRow(context, transport, tempo),
              ],
            ),
            const SizedBox(height: kConsoleBlockGap),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('loop_sync_row'),
                  title: l10n.syncTempoTitle,
                  subtitle: l10n.syncTempoSubtitle,
                  showDivider: false,
                  trailing: ConsoleSwitch(
                    key: const Key('loop_sync_switch'),
                    value: transport.syncTempo,
                    semanticLabel: l10n.syncTempoTitle,
                    onChanged: (on) => unawaited(tempo.setSyncTempo(value: on)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- tempo

  /// The tempo row. Opens the keypad sheet rather than a drawer: a tempo is
  /// typed, not chosen, and the console's number entry is a sheet
  /// (`NETWORK / wifi-password` draws the same shape for a passphrase).
  Widget _tempoRow(BuildContext context, TransportState transport) {
    final l10n = context.l10n;
    return ConsoleRow(
      key: const Key('loop_tempo_row'),
      title: l10n.loopTempoRow,
      subtitle: l10n.loopTempoHint,
      // `0` is "no tempo has ever been established", which is a different
      // fact from "the tempo is zero" — the console says which.
      state: transport.tempoBpm > 0
          ? l10n.loopTempoReadout(transport.tempoBpm.toStringAsFixed(1))
          : l10n.loopTempoUnset,
      expanded: false,
      onTap: () => unawaited(showTempoKeypadSheet(context)),
    );
  }

  // ------------------------------------------------------------- signature

  List<Widget> _signatureRow(
    BuildContext context,
    TransportState transport,
    TempoCubit tempo,
  ) {
    final l10n = context.l10n;
    final open = _open == _TempoRow.signature;
    return [
      ConsoleRow(
        key: const Key('loop_signature_row'),
        title: l10n.timeSignatureLabel,
        state: l10n.timeSignatureOption(transport.tsNum, transport.tsDen),
        expanded: open,
        fill: open ? context.surface.control : null,
        onTap: () => _toggle(_TempoRow.signature),
      ),
      _grid<(int, int)>(
        slot: 'loop_signature_slot',
        open: open,
        current: (transport.tsNum, transport.tsDen),
        options: [
          for (final ts in kValidTimeSignatures)
            ConsoleSegment(
              value: ts,
              label: l10n.timeSignatureOption(ts.$1, ts.$2),
              optionKey: Key('loop_signature_${ts.$1}_${ts.$2}'),
            ),
        ],
        onPick: (ts) => unawaited(tempo.setTimeSignature(ts.$1, ts.$2)),
      ),
    ];
  }

  // ---------------------------------------------------------------- length

  /// The multiples offered: Auto, then a fixed count of base loops.
  ///
  /// The mockups draw "8 bars" here, and the app has no bars figure behind
  /// this setting — what it has is a multiple of the base loop the first take
  /// defines. The row says the multiple.
  static const List<int> _multiples = [0, 1, 2, 3];

  List<Widget> _lengthRow(
    BuildContext context,
    int multiple,
    RecordOptionsCubit options,
  ) {
    final l10n = context.l10n;
    final open = _open == _TempoRow.length;
    String label(int value) =>
        value == 0 ? l10n.loopLengthAuto : l10n.loopLengthMultiple(value);
    return [
      ConsoleRow(
        key: const Key('loop_length_row'),
        title: l10n.loopLength,
        // Only while it reads Auto: once a fixed multiple is set, the first
        // take no longer sets it and the subtitle would be a lie.
        subtitle: multiple == 0 ? l10n.loopLengthHint : null,
        state: label(multiple),
        expanded: open,
        fill: open ? context.surface.control : null,
        onTap: () => _toggle(_TempoRow.length),
      ),
      _grid<int>(
        slot: 'loop_length_slot',
        open: open,
        current: multiple,
        options: [
          for (final value in _multiples)
            ConsoleSegment(
              value: value,
              label: label(value),
              optionKey: Key('loop_length_$value'),
            ),
        ],
        onPick: (value) => unawaited(options.setDefaultMultiple(value)),
      ),
    ];
  }

  // -------------------------------------------------------------- quantise

  List<Widget> _quantiseRow(
    BuildContext context,
    TransportState transport,
    TempoCubit tempo,
  ) {
    final l10n = context.l10n;
    final open = _open == _TempoRow.quantise;
    final labels = {
      GridDivision.off: l10n.quantizeDivOffLabel,
      GridDivision.bar: l10n.quantizeDivBarLabel,
      GridDivision.half: l10n.quantizeDivHalfLabel,
      GridDivision.quarter: l10n.quantizeDivQuarterLabel,
      GridDivision.eighth: l10n.quantizeDivEighthLabel,
      GridDivision.sixteenth: l10n.quantizeDivSixteenthLabel,
    };
    return [
      ConsoleRow(
        key: const Key('loop_quantise_row'),
        title: l10n.loopQuantiseRow,
        subtitle: l10n.loopQuantiseHint,
        state: labels[transport.quantizeDiv],
        expanded: open,
        fill: open ? context.surface.control : null,
        onTap: () => _toggle(_TempoRow.quantise),
      ),
      _grid<GridDivision>(
        slot: 'loop_quantise_slot',
        open: open,
        current: transport.quantizeDiv,
        options: [
          for (final div in GridDivision.values)
            ConsoleSegment(
              value: div,
              label: labels[div]!,
              optionKey: Key('loop_quantise_${div.name}'),
            ),
        ],
        onPick: (div) => unawaited(tempo.setQuantizeDiv(div)),
      ),
    ];
  }

  // -------------------------------------------------------------- count-in

  /// Count-in lengths in measures, `0` being off — the set the Settings
  /// picker already offers.
  static const List<int> _countIns = [0, 1, 2, 4];

  List<Widget> _countInRow(
    BuildContext context,
    TransportState transport,
    TempoCubit tempo,
  ) {
    final l10n = context.l10n;
    final open = _open == _TempoRow.countIn;
    final labels = {
      0: l10n.countInOffLabel,
      1: l10n.countInBarsLabel1,
      2: l10n.countInBarsLabel2,
      4: l10n.countInBarsLabel4,
    };
    return [
      ConsoleRow(
        key: const Key('loop_count_in_row'),
        title: l10n.loopCountInRow,
        state: labels[transport.countInBars] ?? l10n.countInOffLabel,
        expanded: open,
        showDivider: false,
        fill: open ? context.surface.control : null,
        onTap: () => _toggle(_TempoRow.countIn),
      ),
      _grid<int>(
        slot: 'loop_count_in_slot',
        open: open,
        current: transport.countInBars,
        options: [
          for (final bars in _countIns)
            ConsoleSegment(
              value: bars,
              label: labels[bars]!,
              optionKey: Key('loop_count_in_$bars'),
            ),
        ],
        onPick: (bars) => unawaited(tempo.setCountInBars(bars)),
      ),
    ];
  }
}
