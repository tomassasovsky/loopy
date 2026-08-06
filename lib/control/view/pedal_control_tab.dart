import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';

/// The Pedal tab of the console's Control domain, drawn to `CONTROL / pedal`
/// and its states (`pedal-selected`, `pedal-slots`, `pedal-bank-b`,
/// `pedal-stale`).
///
/// Two groups, because the pedal has two kinds of assignable switch:
///
/// - **Transport switches** — Rec/Play, Stop, Undo, Clear — as cards. Four of
///   them, always the same four, one binding each.
/// - **Track switches** — the four track footswitches — as a list under an
///   A/B selector, because each holds a binding PER BANK (A3). Eight slots as
///   eight more cards would outweigh the four above them; as rows they read
///   as the qualified, secondary thing they are.
///
/// Selecting either opens the same assign list: named racks first, because a
/// binding to a rack survives its contents being re-arranged, then individual
/// effects behind "Show individual effects", since a binding to one slot
/// breaks when that slot moves.
///
/// The pedal plate is deliberately absent — it is a picture of hardware you
/// are standing on, and what this surface is for is choosing a target, which
/// is a list.
class PedalControlTab extends StatefulWidget {
  /// Creates a [PedalControlTab].
  const PedalControlTab({super.key});

  @override
  State<PedalControlTab> createState() => _PedalControlTabState();
}

class _PedalControlTabState extends State<PedalControlTab> {
  /// The switch being assigned, or null when nothing is selected — the
  /// `CONTROL / pedal` base state.
  PedalButton? _selected;

  /// Whether the assign list has been expanded past the named racks.
  bool _showSlots = false;

  /// The bank the track rows are showing. Seeded on first build from the bank
  /// the pedal is actually on: editing the bank the performer is standing in
  /// is the common case, and starting anywhere else invites an edit that
  /// appears to do nothing.
  int? _bank;

  /// The transport switches, in floor order. Mode and Bank are missing by
  /// rule — neither can ever hold a binding (B12), since Mode is the only way
  /// out of FX mode and Bank the only way to reach the other four tracks.
  static const List<PedalButton> _transport = [
    PedalButton.recPlay,
    PedalButton.stop,
    PedalButton.undo,
    PedalButton.clear,
  ];

  static const List<PedalButton> _tracks = [
    PedalButton.track1,
    PedalButton.track2,
    PedalButton.track3,
    PedalButton.track4,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.watch<ControlCubit>();
    final looper = context.read<LooperRepository>();
    // What the tracks are CALLED — a target list that says "Track 3" when the
    // rig calls it "rhythm" is a list you have to translate in your head.
    final names = context.watch<TracksCubit>().state.names;
    final editing = cubit.state.bindings;
    final selected = _selected;
    final bank = _bank ??= cubit.state.activeBank;

    return KeyedSubtree(
      key: const Key('pedal_control_tab'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConsoleGroupLabel(l10n.pedalControlTransportGroup),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final button in _transport) ...[
                if (button != _transport.first) const SizedBox(width: 14),
                Expanded(
                  child: _SwitchCard(
                    button: button,
                    label: _targetLabel(l10n, looper, editing, button, names),
                    assigned: _bindingFor(editing, button) != null,
                    selected: selected == button,
                    onTap: () => _select(button),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              ConsoleGroupLabel(l10n.pedalControlTrackGroup),
              const SizedBox(width: 14),
              ConsoleMiniToggle<int>(
                key: const Key('pedal_bank'),
                selected: bank,
                semanticLabel: l10n.pedalControlTrackGroup,
                onChanged: (next) => setState(() => _bank = next),
                options: [
                  for (var b = 0; b < PedalBindingKey.bankCount; b++)
                    ConsoleSegment(
                      value: b,
                      // The letter alone: the caption beside it already says
                      // which group the bank belongs to.
                      label: String.fromCharCode(65 + b),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          ConsoleCard(
            children: [
              for (final button in _tracks)
                ConsoleRow(
                  key: Key('pedal_switch_${button.name}'),
                  title: pedalButtonLabel(l10n, button),
                  value: _targetLabel(l10n, looper, editing, button, names),
                  valueColor: _valueColour(surface, looper, editing, button),
                  expanded: selected == button,
                  selected: selected == button,
                  divider: button != _tracks.last,
                  onTap: () => _select(button),
                ),
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: 14),
            ConsoleGroupLabel(_assignLabel(l10n, selected, bank)),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: _AssignList(
                  bindingKey: _keyFor(selected),
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

  void _select(PedalButton button) => setState(() {
    _selected = _selected == button ? null : button;
    _showSlots = false;
  });

  /// The key a binding for [button] is stored under: bank-qualified for a
  /// track switch, bare for the rest.
  PedalBindingKey _keyFor(PedalButton button) => PedalBindingKey(
    button: button,
    bank: PedalBindingKey.isBankKeyed(button) ? _bank : null,
  );

  PedalBinding? _bindingFor(PedalBindingSet set, PedalButton button) {
    final key = _keyFor(button);
    return set.bindings.where((b) => b.key == key).firstOrNull;
  }

  /// Whether [button]'s binding points at something that no longer exists.
  bool _isStale(
    LooperRepository looper,
    PedalBindingSet set,
    PedalButton button,
  ) {
    final binding = _bindingFor(set, button);
    if (binding == null) return false;
    final target = binding.decodeTarget();
    return target == null || !looper.bindingResolves(target);
  }

  /// The tone a track row's value takes: warning for a binding whose target is
  /// gone, muted for an empty slot, the row's own default otherwise. A missing
  /// target in the muted grey of "unassigned" reads as nothing being set,
  /// which is a different and wrong fact.
  Color? _valueColour(
    SurfaceTheme surface,
    LooperRepository looper,
    PedalBindingSet set,
    PedalButton button,
  ) {
    if (_isStale(looper, set, button)) return surface.warning;
    if (_bindingFor(set, button) == null) return surface.textMuted;
    return null;
  }

  /// What a switch drives, or why it drives nothing.
  String _targetLabel(
    AppLocalizations l10n,
    LooperRepository looper,
    PedalBindingSet set,
    PedalButton button,
    List<String> names,
  ) {
    final binding = _bindingFor(set, button);
    if (binding == null) return l10n.pedalControlUnassigned;
    if (_isStale(looper, set, button)) return l10n.pedalControlMissingTarget;
    return bindingTargetLabel(l10n, binding.decodeTarget()!, trackNames: names);
  }

  /// Names what the assign list is assigning — and, for a track switch, which
  /// bank it lands in, so an edit cannot silently go to the other one.
  String _assignLabel(AppLocalizations l10n, PedalButton button, int bank) {
    final name = pedalButtonLabel(l10n, button);
    if (!PedalBindingKey.isBankKeyed(button)) {
      return l10n.pedalControlAssign(name);
    }
    return l10n.pedalControlAssignBank(name, String.fromCharCode(65 + bank));
  }
}

/// One transport switch: its hardware name over what it drives, tinted while
/// it is the switch being assigned.
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
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pedalButtonLabel(context.l10n, button).toUpperCase(),
                style: TextStyle(
                  color: surface.textMuted,
                  fontSize: 12,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  // An unassigned switch says so in the muted voice: it is an
                  // absence, not a name.
                  color: assigned ? surface.textPrimary : surface.textMuted,
                  fontSize: 16,
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
class _AssignList extends StatelessWidget {
  const _AssignList({
    required this.bindingKey,
    required this.showSlots,
    required this.onShowSlots,
  });

  /// The key being edited — bank-qualified for a track switch.
  final PedalBindingKey bindingKey;

  /// Whether the list has been expanded past the named racks.
  final bool showSlots;

  /// Expands it.
  final VoidCallback onShowSlots;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.watch<ControlCubit>();
    final looper = context.read<LooperRepository>();
    // What the tracks are CALLED — a target list that says "Track 3" when the
    // rig calls it "rhythm" is a list you have to translate in your head.
    final names = context.watch<TracksCubit>().state.names;
    final editing = cubit.state.bindings;
    final current = editing.bindings
        .where((b) => b.key == bindingKey)
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
          PedalBinding(key: bindingKey, target: target.canonicalString()),
        ),
      );
    }

    return ConsoleCard(
      children: [
        for (final target in rows)
          ConsoleRow(
            key: Key('pedal_target_${target.canonicalString().hashCode}'),
            title: _title(l10n, target, names),
            showDisclosure: false,
            indented: target is FxSlotTarget,
            divider: target != rows.last || !showSlots,
            onTap: () => unawaited(assign(target)),
            value: target == current ? null : _placement(l10n, target, names),
            // The current value is CHECKED, not tinted: tint already means
            // "the row you opened", and one mark cannot carry two meanings on
            // the same pane.
            trailing: target == current
                ? Row(
                    key: const Key('pedal_target_current'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _placement(l10n, target, names),
                        style: TextStyle(color: surface.accent, fontSize: 14),
                      ),
                      const SizedBox(width: 14),
                      Icon(Icons.check, size: 18, color: surface.accent),
                    ],
                  )
                : null,
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
  String _title(
    AppLocalizations l10n,
    FxBindingTarget target,
    List<String> names,
  ) => switch (target) {
    FxChainTarget() => bindingTargetLabel(l10n, target, trackNames: names),
    FxSlotTarget(:final slotId) => slotId,
  };

  /// Where in the rig the target sits, down the right-hand edge as drawn.
  String _placement(
    AppLocalizations l10n,
    FxBindingTarget target,
    List<String> names,
  ) => switch (target) {
    FxChainTarget() => fxStageLabel(l10n, target.address, trackNames: names),
    FxSlotTarget() => l10n.pedalControlInChain(
      fxStageLabel(l10n, target.address, trackNames: names),
    ),
  };
}
