import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/loop/tempo_sheet.dart';

/// The Tempo tab of the console's Loop domain, drawn to `LOOP / loop`.
///
/// The grid itself: what the tempo is, how it is counted, how long a loop
/// runs, and when a switch takes effect. Every row is a value the rig already
/// holds — this face is a presentation of `TempoCubit`, not a second copy of
/// its rules.
class TempoLoopTab extends StatelessWidget {
  /// Creates a [TempoLoopTab].
  const TempoLoopTab({super.key});

  /// Time signatures worth offering on a looper: everything a bar count has to
  /// divide cleanly.
  static const List<(int, int)> _signatures = [
    (4, 4),
    (3, 4),
    (6, 8),
    (5, 4),
    (7, 8),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tempo = context.watch<TempoCubit>();
    final state = tempo.state;
    final record = context.watch<RecordOptionsCubit>();

    return KeyedSubtree(
      key: const Key('tempo_loop_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.loopTempoGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('loop_tempo_row'),
                  title: l10n.loopTempoTitle,
                  subtitle: l10n.loopTempoSubtitle,
                  value: l10n.loopBpmValue(state.bpm.toStringAsFixed(1)),
                  onTap: () => unawaited(_editTempo(context, tempo)),
                ),
                ConsoleRow(
                  key: const Key('loop_signature_row'),
                  title: l10n.loopSignatureTitle,
                  value: '${state.tsNum}/${state.tsDen}',
                  onTap: () => unawaited(_pickSignature(context, tempo)),
                ),
                ConsoleRow(
                  key: const Key('loop_length_row'),
                  title: l10n.loopLengthTitle,
                  // The app has no bar figure for this: the setting is a
                  // MULTIPLE of the base loop the first take defines, which
                  // is what "first take sets it" means when it reads Auto.
                  subtitle: record.state.defaultMultiple == 0
                      ? l10n.loopLengthSubtitle
                      : null,
                  value: _multipleLabel(l10n, record.state.defaultMultiple),
                  onTap: () => unawaited(_pickMultiple(context, record)),
                ),
                ConsoleRow(
                  key: const Key('loop_quantise_row'),
                  title: l10n.loopQuantiseTitle,
                  subtitle: l10n.loopQuantiseSubtitle,
                  value: _divisionLabel(l10n, state.quantizeDiv),
                  onTap: () => unawaited(_pickQuantise(context, tempo)),
                ),
                ConsoleRow(
                  key: const Key('loop_countin_row'),
                  divider: false,
                  title: l10n.loopCountInTitle,
                  value: _barsLabel(l10n, state.countInBars),
                  onTap: () => unawaited(_pickCountIn(context, tempo)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleCard(
              children: [
                ConsoleRow(
                  divider: false,
                  title: l10n.loopSyncTitle,
                  subtitle: l10n.loopSyncSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('loop_sync_switch'),
                    value: state.syncTempo,
                    semanticLabel: l10n.loopSyncTitle,
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

  Future<void> _editTempo(BuildContext context, TempoCubit tempo) async {
    final bpm = await showTempoSheet(
      context,
      initial: tempo.state.bpm,
      onTap: tempo.tapTempo,
    );
    if (bpm == null) return;
    await tempo.setTempo(bpm);
  }

  Future<void> _pickSignature(BuildContext context, TempoCubit tempo) async {
    final chosen = await showConsolePickerSheet<(int, int)>(
      context,
      title: context.l10n.loopSignatureTitle,
      selected: (tempo.state.tsNum, tempo.state.tsDen),
      options: [
        for (final (num, den) in _signatures)
          ConsolePickerOption(value: (num, den), label: '$num/$den'),
      ],
    );
    if (chosen == null) return;
    await tempo.setTimeSignature(chosen.$1, chosen.$2);
  }

  Future<void> _pickQuantise(BuildContext context, TempoCubit tempo) async {
    final l10n = context.l10n;
    final chosen = await showConsolePickerSheet<GridDivision>(
      context,
      title: l10n.loopQuantiseTitle,
      selected: tempo.state.quantizeDiv,
      options: [
        for (final division in GridDivision.values)
          ConsolePickerOption(
            value: division,
            label: _divisionLabel(l10n, division),
          ),
      ],
    );
    if (chosen == null) return;
    await tempo.setQuantizeDiv(chosen);
  }

  Future<void> _pickCountIn(BuildContext context, TempoCubit tempo) async {
    final l10n = context.l10n;
    final chosen = await showConsolePickerSheet<int>(
      context,
      title: l10n.loopCountInTitle,
      selected: tempo.state.countInBars,
      options: [
        for (final bars in const [0, 1, 2, 4])
          ConsolePickerOption(value: bars, label: _barsLabel(l10n, bars)),
      ],
    );
    if (chosen == null) return;
    await tempo.setCountInBars(chosen);
  }

  Future<void> _pickMultiple(
    BuildContext context,
    RecordOptionsCubit record,
  ) async {
    final l10n = context.l10n;
    final chosen = await showConsolePickerSheet<int>(
      context,
      title: l10n.loopLengthTitle,
      selected: record.state.defaultMultiple,
      options: [
        for (final multiple in const [0, 1, 2, 3])
          ConsolePickerOption(
            value: multiple,
            label: _multipleLabel(l10n, multiple),
          ),
      ],
    );
    if (chosen == null) return;
    await record.setDefaultMultiple(chosen);
  }

  String _multipleLabel(AppLocalizations l10n, int multiple) =>
      multiple == 0 ? l10n.auto : l10n.loopMultipleLabel(multiple);

  String _barsLabel(AppLocalizations l10n, int bars) =>
      bars == 0 ? l10n.loopCountInOff : l10n.loopBarsValue(bars);

  String _divisionLabel(AppLocalizations l10n, GridDivision division) =>
      switch (division) {
        GridDivision.off => l10n.loopQuantiseOff,
        GridDivision.bar => l10n.loopBarsValue(1),
        GridDivision.half => l10n.loopDivisionHalf,
        GridDivision.quarter => l10n.loopDivisionQuarter,
        GridDivision.eighth => l10n.loopDivisionEighth,
        GridDivision.sixteenth => l10n.loopDivisionSixteenth,
      };
}
