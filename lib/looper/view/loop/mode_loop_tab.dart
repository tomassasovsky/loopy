import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/loop/looper_mode_change.dart';

/// The Mode tab of the console's Loop domain, drawn to `LOOP / loop-mode`:
/// which looper mode the tracks obey, whether they one-shot, and what the
/// pedal starts in.
class ModeLoopTab extends StatelessWidget {
  /// Creates a [ModeLoopTab].
  const ModeLoopTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looper = context.watch<LooperBloc>().state;
    final control = context.watch<ControlCubit>();

    return KeyedSubtree(
      key: const Key('mode_loop_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.loopModeGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('looper_mode_row'),
                  title: l10n.loopModeTitle,
                  subtitle: looperModeLabels(
                    l10n,
                    looper.transport.looperMode,
                  ).$2,
                  value: looperModeLabels(l10n, looper.transport.looperMode).$1,
                  onTap: () => unawaited(
                    _pickMode(context, looper.transport.looperMode),
                  ),
                ),
                ConsoleRow(
                  key: const Key('one_shot_row'),
                  divider: false,
                  title: l10n.loopOneShotTitle,
                  subtitle: l10n.oneShotIntro,
                  trailing: ConsoleSwitch(
                    key: const Key('one_shot_switch'),
                    // One-shot is per track in the engine; this is the rig
                    // default applied to every track at once, which is what
                    // the mockups' single switch means. `every` on no tracks
                    // is vacuously true, which read as "on" before a session
                    // had anything in it.
                    value:
                        looper.tracks.isNotEmpty &&
                        looper.tracks.every((t) => t.oneShot),
                    semanticLabel: l10n.loopOneShotTitle,
                    onChanged: (on) {
                      final bloc = context.read<LooperBloc>();
                      for (var i = 0; i < looper.tracks.length; i++) {
                        bloc.add(LooperOneShotToggled(i, oneShot: on));
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleGroupLabel(l10n.loopDefaultsGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('default_mode_row'),
                  divider: false,
                  title: l10n.defaultModeTitle,
                  value: _defaultModeLabel(l10n, control.state.defaultMode),
                  onTap: () => unawaited(_pickDefaultMode(context, control)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMode(BuildContext context, LooperMode current) async {
    final l10n = context.l10n;
    final chosen = await showConsolePickerSheet<LooperMode>(
      context,
      title: l10n.loopModeTitle,
      selected: current,
      options: [
        for (final mode in LooperMode.values)
          ConsolePickerOption(
            value: mode,
            label: looperModeLabels(l10n, mode).$1,
            // Naming five modes without saying what they do makes the picker
            // a quiz. Same blurb the face shows under the current value.
            subtitle: looperModeLabels(l10n, mode).$2,
          ),
      ],
    );
    if (chosen == null || !context.mounted) return;
    // The shared rule: clearing first when there is content, and waiting for
    // the bloc to report cleared before switching (D4).
    await requestLooperModeChange(context, current: current, next: chosen);
  }

  Future<void> _pickDefaultMode(
    BuildContext context,
    ControlCubit control,
  ) async {
    final l10n = context.l10n;
    final chosen = await showConsolePickerSheet<InteractionMode>(
      context,
      title: l10n.defaultModeTitle,
      selected: control.state.defaultMode,
      options: [
        // Record and Mute only: FX mode is entered from the pedal, never a
        // state the console boots into (the Settings page offers the same
        // two).
        for (final mode in const [InteractionMode.record, InteractionMode.mute])
          ConsolePickerOption(
            value: mode,
            label: _defaultModeLabel(l10n, mode),
          ),
      ],
    );
    if (chosen == null) return;
    await control.setDefaultMode(chosen);
  }

  String _defaultModeLabel(AppLocalizations l10n, InteractionMode mode) =>
      switch (mode) {
        InteractionMode.record => l10n.recordModeLabel,
        InteractionMode.mute => l10n.muteModeLabel,
        InteractionMode.fx => l10n.fxModeLabel,
      };
}
