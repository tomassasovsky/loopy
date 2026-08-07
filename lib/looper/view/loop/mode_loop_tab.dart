import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/looper_mode_change.dart';
import 'package:segno/theme/theme.dart';

/// Exactly what the Mode face draws. See `TempoLoopTab` for why this is a
/// record fed to `context.select` rather than the whole `LooperState`.
typedef _ModeValues = ({
  LooperMode mode,
  bool allOneShot,
  bool hasTracks,
});

_ModeValues _modeValues(LooperState state) => (
  mode: state.transport.looperMode,
  allOneShot: state.allOneShot,
  hasTracks: state.tracks.isNotEmpty,
);

/// Which row of the Mode face has its chooser open. See `TempoLoopTab` for
/// why at most one.
enum _ModeRow {
  /// The five-mode axis.
  looper,

  /// The mode the rig boots into.
  boot,
}

/// The Mode tab of the Loop domain: the five-mode axis, whether tracks play
/// once, and the mode the rig boots into.
///
/// The mode itself is live off [LooperBloc]'s `TransportState` — a pedal or a
/// session load moves it without this face being told. The boot default is
/// [ControlCubit]'s, because it is intent by definition: it is what the rig
/// will do next time, not what it is doing.
class ModeLoopTab extends StatefulWidget {
  /// Creates a [ModeLoopTab].
  const ModeLoopTab({super.key});

  @override
  State<ModeLoopTab> createState() => _ModeLoopTabState();
}

class _ModeLoopTabState extends State<ModeLoopTab> {
  _ModeRow? _open;

  void _toggle(_ModeRow row) =>
      setState(() => _open = _open == row ? null : row);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looper = context.select<LooperBloc, _ModeValues>(
      (bloc) => _modeValues(bloc.state),
    );
    final defaultMode = context.select<ControlCubit, InteractionMode>(
      (cubit) => cubit.state.defaultMode,
    );

    return KeyedSubtree(
      key: const Key('loop_mode_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: kConsoleGroupGap),
            ConsoleGroupLabel(l10n.loopModeGroup),
            const SizedBox(height: kConsoleLabelGap),
            ConsoleCard(
              children: [
                ..._looperModeRow(context, looper),
                _oneShotRow(context, looper),
              ],
            ),
            const SizedBox(height: kConsoleGroupGap),
            ConsoleGroupLabel(l10n.loopDefaultsGroup),
            const SizedBox(height: kConsoleLabelGap),
            ConsoleCard(children: _defaultModeRow(context, defaultMode)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ looper mode

  List<Widget> _looperModeRow(BuildContext context, _ModeValues looper) {
    final l10n = context.l10n;
    final labels = looperModeLabels(l10n);
    final mode = looper.mode;
    final open = _open == _ModeRow.looper;
    return [
      ConsoleRow(
        key: const Key('loop_mode_row'),
        title: l10n.loopModeRow,
        subtitle: labels[mode]?.sub,
        state: labels[mode]?.label,
        expanded: open,
        fill: open ? context.surface.control : null,
        onTap: () => _toggle(_ModeRow.looper),
      ),
      ConsoleChooser(
        key: const Key('loop_mode_slot'),
        open: open,
        children: [
          for (final (index, value) in LooperMode.values.indexed)
            ConsolePickRow(
              key: Key('loop_mode_${value.name}'),
              title: labels[value]!.label,
              // The one-liner is what makes five bare names choosable; it
              // rides at the trailing edge, where a pick row's own facts go.
              state: labels[value]!.sub,
              selected: value == mode,
              showDivider: index < LooperMode.values.length - 1,
              // The chooser stays open across the confirm and shuts only if
              // the switch went through — `LOOP / settings-mode-confirm`
              // draws the mode list still open behind the dialog, and a
              // declined confirm leaves the user still choosing.
              //
              // Re-picking the mode already lit is not a declined confirm: it
              // is an answer, and every other chooser on these faces shuts on
              // one. `requestLooperModeChange` reports false for it (there is
              // nothing to dispatch), so it shuts here instead.
              onTap: () async {
                if (value == mode) {
                  setState(() => _open = null);
                  return;
                }
                final switched = await requestLooperModeChange(
                  context,
                  current: mode,
                  next: value,
                );
                if (switched && mounted) setState(() => _open = null);
              },
            ),
        ],
      ),
    ];
  }

  // ---------------------------------------------------------------- one-shot

  /// The rig-wide one-shot switch.
  ///
  /// Both the read and the write are the bloc's: [LooperState.allOneShot]
  /// carries the vacuous-truth guard (`every` on an empty list is true, which
  /// is never what the row means) and [LooperAllOneShotToggled] applies the
  /// sweep in one event, so the rule is testable without a widget and a
  /// half-applied sweep cannot be observed. Inert while there is nothing to
  /// apply it to.
  Widget _oneShotRow(BuildContext context, _ModeValues looper) {
    final l10n = context.l10n;
    final bloc = context.read<LooperBloc>();
    return ConsoleRow(
      key: const Key('loop_one_shot_row'),
      title: l10n.loopOneShotRow,
      subtitle: l10n.oneShotIntro,
      showDivider: false,
      trailing: ConsoleSwitch(
        key: const Key('loop_one_shot_switch'),
        value: looper.allOneShot,
        semanticLabel: l10n.loopOneShotRow,
        onChanged: looper.hasTracks
            ? (on) => bloc.add(LooperAllOneShotToggled(oneShot: on))
            : null,
      ),
    );
  }

  // ------------------------------------------------------------ boot default

  List<Widget> _defaultModeRow(BuildContext context, InteractionMode current) {
    final l10n = context.l10n;
    final cubit = context.read<ControlCubit>();
    final open = _open == _ModeRow.boot;
    // FX is deliberately absent (R12): booting into it with no chains
    // configured is a dead surface, so it is reached by cycling only.
    final labels = {
      InteractionMode.record: (
        name: l10n.recordModeLabel,
        sub: l10n.recordModeSub,
        state: l10n.loopDefaultModeRecord,
      ),
      InteractionMode.mute: (
        name: l10n.muteModeLabel,
        sub: l10n.muteModeSub,
        state: l10n.loopDefaultModeMute,
      ),
    };
    return [
      ConsoleRow(
        key: const Key('loop_default_mode_row'),
        title: l10n.loopDefaultModeRow,
        state: labels[current]?.state,
        expanded: open,
        showDivider: false,
        fill: open ? context.surface.control : null,
        onTap: () => _toggle(_ModeRow.boot),
      ),
      ConsoleChooser(
        key: const Key('loop_default_mode_slot'),
        open: open,
        children: [
          for (final (index, mode) in InteractionMode.bootDefaults.indexed)
            ConsolePickRow(
              key: Key('loop_default_mode_${mode.name}'),
              title: labels[mode]!.name,
              state: labels[mode]!.sub,
              selected: mode == current,
              showDivider: index < InteractionMode.bootDefaults.length - 1,
              onTap: () {
                setState(() => _open = null);
                unawaited(cubit.setDefaultMode(mode));
              },
            ),
        ],
      ),
    ];
  }
}
