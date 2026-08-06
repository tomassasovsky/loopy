import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/loop/tempo_sheet.dart';

/// The Tempo tab of the console's Loop domain, drawn to `LOOP / loop`.
///
/// The grid itself: what the tempo is, how it is counted, how long a loop
/// runs, and when a switch takes effect.
///
/// Every live value is read from [LooperBloc]'s [TransportState], never from
/// [TempoCubit]'s own state — same rule `TempoSettingsSection` documents.
/// [TempoCubit] holds the *explicitly configured* intent, which is `0` until
/// someone types a tempo and never moves when one is tapped or derived from a
/// loop; the transport holds what the rig is actually running on. Reading the
/// cubit here is what made tap tempo look broken: the taps landed, the engine
/// converged, and this face went on showing the intent.
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
    final tempo = context.read<TempoCubit>();
    final transport = context.watch<LooperBloc>().state.transport;
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
                  value: transport.tempoBpm > 0
                      ? l10n.loopBpmValue(transport.tempoBpm.toStringAsFixed(1))
                      : l10n.tempoNotSetLabel,
                  onTap: () => unawaited(_editTempo(context, tempo)),
                ),
                ConsoleRow(
                  key: const Key('loop_signature_row'),
                  title: l10n.loopSignatureTitle,
                  value: '${transport.tsNum}/${transport.tsDen}',
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
                  value: _divisionLabel(l10n, transport.quantizeDiv),
                  onTap: () => unawaited(_pickQuantise(context, tempo)),
                ),
                ConsoleRow(
                  key: const Key('loop_countin_row'),
                  divider: false,
                  title: l10n.loopCountInTitle,
                  value: _barsLabel(l10n, transport.countInBars),
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
                    value: transport.syncTempo,
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
      initial: context.read<LooperBloc>().state.transport.tempoBpm,
      onTap: tempo.tapTempo,
    );
    if (bpm == null) return;
    await tempo.setTempo(bpm);
  }

  Future<void> _pickSignature(BuildContext context, TempoCubit tempo) async {
    final transport = context.read<LooperBloc>().state.transport;
    final l10n = context.l10n;
    final chosen = await showConsoleChipDialog<(int, int)>(
      context,
      title: l10n.loopSignatureTitle,
      explanation: l10n.loopSignatureExplain,
      selected: (transport.tsNum, transport.tsDen),
      options: [
        for (final (num, den) in _signatures)
          ConsoleSegment(value: (num, den), label: '$num/$den'),
      ],
    );
    if (chosen == null) return;
    await tempo.setTimeSignature(chosen.$1, chosen.$2);
  }

  Future<void> _pickQuantise(BuildContext context, TempoCubit tempo) async {
    final l10n = context.l10n;
    final transport = context.read<LooperBloc>().state.transport;
    final chosen = await showConsoleChipDialog<GridDivision>(
      context,
      title: l10n.loopQuantiseTitle,
      explanation: l10n.quantizeDivIntro,
      selected: transport.quantizeDiv,
      options: [
        for (final division in GridDivision.values)
          ConsoleSegment(
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
    final transport = context.read<LooperBloc>().state.transport;
    final chosen = await showConsoleChipDialog<int>(
      context,
      title: l10n.loopCountInTitle,
      explanation: l10n.countInIntro,
      selected: transport.countInBars,
      options: [
        for (final bars in const [0, 1, 2, 4])
          ConsoleSegment(value: bars, label: _barsLabel(l10n, bars)),
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
    final chosen = await showConsoleChipDialog<int>(
      context,
      title: l10n.loopLengthTitle,
      explanation: l10n.loopLengthExplain,
      selected: record.state.defaultMultiple,
      options: [
        for (final multiple in const [0, 1, 2, 3])
          ConsoleSegment(
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
