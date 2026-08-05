import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';

/// The Click tab of the console's Loop domain, drawn to `LOOP / loop-click`:
/// when the metronome plays, where it goes, and how loud.
class ClickLoopTab extends StatelessWidget {
  /// Creates a [ClickLoopTab].
  const ClickLoopTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tempo = context.watch<TempoCubit>();
    final state = tempo.state;

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
                  value: _modeLabel(l10n, state.clickMode),
                  onTap: () => unawaited(_pickMode(context, tempo)),
                ),
                ConsoleRow(
                  key: const Key('click_output_row'),
                  divider: false,
                  title: l10n.loopClickOutputTitle,
                  value: _outputLabel(l10n, state.clickOutputMask),
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
                    value: state.clickVolume,
                    readout: '${(state.clickVolume * 100).round()}%',
                    onChanged: (value) =>
                        unawaited(tempo.setClickVolume(value)),
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
      selected: tempo.state.clickMode,
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
      selected: tempo.state.clickOutputMask,
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
