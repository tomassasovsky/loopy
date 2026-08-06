import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';

/// The Click tab of the console's Loop domain, drawn to `LOOP / loop-click`:
/// when the metronome plays, where it goes, and how loud.
///
/// Live values come from [LooperBloc]'s transport and mutations go through
/// [TempoCubit] — see `TempoLoopTab` for why the two are not interchangeable.
class ClickLoopTab extends StatelessWidget {
  /// Creates a [ClickLoopTab].
  const ClickLoopTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tempo = context.read<TempoCubit>();
    final transport = context.watch<LooperBloc>().state.transport;

    return KeyedSubtree(
      key: const Key('click_loop_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.loopClickGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('click_mode_row'),
                  title: l10n.loopClickWhenTitle,
                  value: _modeLabel(l10n, transport.clickMode),
                  onTap: () => unawaited(_pickMode(context, tempo)),
                ),
                ConsoleRow(
                  key: const Key('click_output_row'),
                  divider: false,
                  title: l10n.loopClickOutputTitle,
                  value: _outputLabel(l10n, transport.clickMask),
                  onTap: () => unawaited(_pickOutput(context, tempo)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleCard(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: ConsoleValueBar(
                    key: const Key('click_volume_bar'),
                    label: l10n.loopClickVolumeLabel,
                    // The bar spans the click's whole gain stage, so the
                    // +6 dB of headroom above unity stays reachable here and
                    // not only on the old settings slider; the readout stays
                    // in the same percent-of-unity the rest of the app uses,
                    // which puts a normal click at half the bar.
                    value: transport.clickVolume / kMaxClickGain,
                    // Double tap returns the click to unity — the one value
                    // on this bar worth aiming at.
                    resetValue: 1 / kMaxClickGain,
                    readout: '${(transport.clickVolume * 100).round()}%',
                    onChanged: (value) =>
                        unawaited(tempo.setClickVolume(value * kMaxClickGain)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMode(BuildContext context, TempoCubit tempo) async {
    final l10n = context.l10n;
    final chosen = await showConsolePickerSheet<ClickMode>(
      context,
      title: l10n.loopClickWhenTitle,
      selected: context.read<LooperBloc>().state.transport.clickMode,
      options: [
        for (final mode in ClickMode.values)
          ConsolePickerOption(value: mode, label: _modeLabel(l10n, mode)),
      ],
    );
    if (chosen == null) return;
    await tempo.setClickMode(chosen);
  }

  Future<void> _pickOutput(BuildContext context, TempoCubit tempo) async {
    final l10n = context.l10n;
    final chosen = await showConsolePickerSheet<int>(
      context,
      title: l10n.loopClickOutputTitle,
      selected: context.read<LooperBloc>().state.transport.clickMask,
      options: [
        for (final mask in const [0, 1, 2, 3])
          ConsolePickerOption(value: mask, label: _outputLabel(l10n, mask)),
      ],
    );
    if (chosen == null) return;
    await tempo.setClickOutput(chosen);
  }

  String _modeLabel(AppLocalizations l10n, ClickMode mode) => switch (mode) {
    ClickMode.off => l10n.loopClickOff,
    ClickMode.rec => l10n.loopClickRecording,
    ClickMode.recFirst => l10n.loopClickFirstTake,
    ClickMode.playRec => l10n.loopClickAlways,
  };

  /// The output mask as words. Bit 0 is the main output, bit 1 the phones —
  /// the same encoding the engine takes, named rather than shown as a number.
  String _outputLabel(AppLocalizations l10n, int mask) => switch (mask) {
    0 => l10n.loopClickOutputNone,
    1 => l10n.loopClickOutputMain,
    2 => l10n.loopClickOutputPhones,
    _ => l10n.loopClickOutputBoth,
  };
}
