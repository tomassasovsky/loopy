import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// The Pedal tab of the console's Control domain, drawn to `CONTROL / control`,
/// `pedal` and `pedal-slots`.
///
/// Four switch cards across the top — the hardware, in the order it sits on the
/// floor — and, once one is selected, the list of what it could drive. The
/// mockups deliberately do NOT draw the pedal plate here: the plate is a
/// picture of hardware you are standing on, and what this surface is for is
/// choosing a target, which is a list.
///
/// Targets come in two depths. Named racks come first, because a switch that
/// bypasses "Dirty rhythm" survives its contents being re-arranged; individual
/// effects are one tap further down, behind "Show individual effects", since a
/// binding to one slot breaks when that slot moves.
class PedalControlTab extends StatefulWidget {
  /// Creates a [PedalControlTab].
  const PedalControlTab({super.key});

  @override
  State<PedalControlTab> createState() => _PedalControlTabState();
}

class _PedalControlTabState extends State<PedalControlTab> {
  /// The switch whose targets are listed, or null when nothing is selected —
  /// the `CONTROL / control` base state, which is four cards and nothing else.
  PedalButton? _selected;

  /// Whether the target list has been expanded past the named racks.
  bool _showSlots = false;

  /// The four assignable floor switches, left to right — the mockups' SW1-SW4
  /// against this pedal's actual hardware.
  ///
  /// The track row is deliberately absent: those buttons hold one binding PER
  /// BANK (A3), and a bank selector does not fit four cards wide. They stay on
  /// the full-screen plate, which has room to show which bank is being edited.
  /// Mode and Bank are unbindable by rule.
  static const List<PedalButton> _switches = [
    PedalButton.recPlay,
    PedalButton.stop,
    PedalButton.undo,
    PedalButton.clear,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<ControlCubit>();
    final looper = context.read<LooperRepository>();
    final editing = cubit.state.bindings;
    final selected = _selected;

    return KeyedSubtree(
      key: const Key('pedal_control_tab'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final button in _switches) ...[
                if (button != _switches.first) const SizedBox(width: 14),
                Expanded(
                  child: _SwitchCard(
                    button: button,
                    label: _targetLabel(l10n, looper, editing, button),
                    assigned: _bindingFor(editing, button) != null,
                    selected: selected == button,
                    onTap: () => setState(() {
                      _selected = selected == button ? null : button;
                      _showSlots = false;
                    }),
                  ),
                ),
              ],
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: _TargetList(
                  button: selected,
                  showSlots: _showSlots,
                  onShowSlots: () => setState(() => _showSlots = true),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  PedalBinding? _bindingFor(PedalBindingSet set, PedalButton button) {
    final key = PedalBindingKey(button: button);
    return set.bindings.where((b) => b.key == key).firstOrNull;
  }

  /// What the card shows under the switch's name: the target it drives, or
  /// "unassigned".
  String _targetLabel(
    AppLocalizations l10n,
    LooperRepository looper,
    PedalBindingSet set,
    PedalButton button,
  ) {
    final binding = _bindingFor(set, button);
    if (binding == null) return l10n.pedalControlUnassigned;
    final target = binding.decodeTarget();
    if (target == null || !looper.bindingResolves(target)) {
      return l10n.pedalControlMissingTarget;
    }
    return bindingTargetLabel(l10n, target);
  }
}

/// One footswitch: its hardware name over what it drives, tinted while it is
/// the switch being assigned.
class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.button,
    required this.label,
    required this.assigned,
    required this.selected,
    required this.onTap,
  });

  final PedalButton button;
  final String label;
  final bool assigned;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: selected ? surface.accentSurface : surface.cardHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? surface.accent : surface.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('pedal_switch_${button.name}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pedalButtonLabel(context.l10n, button).toUpperCase(),
                style: TextStyle(
                  color: surface.textMuted,
                  fontSize: 13,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  // An unassigned switch says so in the muted voice: it is an
                  // absence, not a name.
                  color: assigned ? surface.textPrimary : surface.textMuted,
                  fontSize: 17,
                  fontWeight: assigned ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the selected switch can be pointed at: every named rack, then — on
/// request — every individual effect inside them.
class _TargetList extends StatelessWidget {
  const _TargetList({
    required this.button,
    required this.showSlots,
    required this.onShowSlots,
  });

  final PedalButton button;
  final bool showSlots;
  final VoidCallback onShowSlots;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<ControlCubit>();
    final looper = context.read<LooperRepository>();
    final key = PedalBindingKey(button: button);
    final editing = cubit.state.bindings;
    final current = editing.bindings
        .where((b) => b.key == key)
        .firstOrNull
        ?.decodeTarget();

    final targets = looper.availableBindingTargets();
    final chains = targets.whereType<FxChainTarget>().toList();
    final slots = targets.whereType<FxSlotTarget>().toList();
    final rows = <FxBindingTarget>[...chains, if (showSlots) ...slots];

    // Editing writes to the GLOBAL set even when a session remap is in force,
    // promoting it — the same rule (and reasoning) as the full-screen plate,
    // which must not disagree with this surface about where an edit lands.
    Future<void> assign(FxBindingTarget target) async {
      if (cubit.state.sessionBindings.isNotEmpty) {
        cubit.applySessionBindings(PedalBindingSet.empty);
      }
      await cubit.setGlobalBindings(
        editing.withBinding(
          PedalBinding(key: key, target: target.canonicalString()),
        ),
      );
    }

    return ConsoleCard(
      children: [
        for (final target in rows)
          ConsoleRow(
            key: Key('pedal_target_${target.canonicalString().hashCode}'),
            title: _title(l10n, target),
            value: _placement(l10n, target),
            showDisclosure: false,
            selected: current == target,
            indented: target is FxSlotTarget,
            divider: target != rows.last || !showSlots,
            onTap: () => unawaited(assign(target)),
          ),
        if (!showSlots)
          ConsoleRow(
            key: const Key('pedal_show_slots'),
            title: l10n.pedalControlShowSlots,
            centred: true,
            divider: false,
            showDisclosure: false,
            onTap: onShowSlots,
          ),
      ],
    );
  }

  /// The target's own name.
  ///
  /// The mockups show user-given rack names ("Dirty rhythm"); the rig has no
  /// such thing yet — a chain is identified by where it sits — so the shared
  /// [bindingTargetLabel] vocabulary is used instead, and an effect row is
  /// named by its slot rather than repeating its chain.
  String _title(AppLocalizations l10n, FxBindingTarget target) =>
      switch (target) {
        FxChainTarget() => bindingTargetLabel(l10n, target),
        FxSlotTarget(:final slotId) => slotId,
      };

  /// Where in the rig the target sits, down the right-hand edge as drawn: the
  /// stage for a rack, the containing chain for one effect inside it.
  String _placement(AppLocalizations l10n, FxBindingTarget target) =>
      switch (target) {
        FxChainTarget() => fxStageLabel(l10n, target.address),
        FxSlotTarget() => l10n.pedalControlInChain(
          fxStageLabel(l10n, target.address),
        ),
      };
}
