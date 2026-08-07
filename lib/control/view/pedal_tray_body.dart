import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';

/// The Pedal tab of the Control domain: which footswitch you are editing, and
/// what it acts on in FX mode.
///
/// **No plate.** The full-screen assignment surface draws a scale diagram of
/// the real top plate, which is the right picture when the question is *where
/// is that switch under my foot*. The question here is *what should it do*,
/// and that is a list.
///
/// The four transport switches are cards and the four track switches are a
/// list, because a track switch holds a binding **per bank** (A3): four caps,
/// eight assignable slots. Eight cards would have outweighed the four above
/// them, so the bank is a selector beside the caption and the list shows one
/// bank at a time.
///
/// MODE and Bank appear nowhere: neither can ever hold a binding (B12), and a
/// card that exists only to refuse is worse than no card.
class PedalTrayBody extends StatefulWidget {
  /// Creates a [PedalTrayBody].
  const PedalTrayBody({super.key});

  @override
  State<PedalTrayBody> createState() => _PedalTrayBodyState();
}

class _PedalTrayBodyState extends State<PedalTrayBody> {
  /// The switch whose targets are listed, or null when none is being edited.
  PedalButton? _selected;

  /// The bank the track list is showing. Null until first read, so it can seed
  /// from the bank the pedal is actually on: editing the bank the performer is
  /// standing in is the common case, and starting anywhere else invites an
  /// edit that appears to do nothing.
  int? _bank;

  /// Whether the assign list is also offering the individual effect slots.
  bool _showEffects = false;

  /// Height of one transport card.
  static const double _cardHeight = 101;

  /// Gap between the transport cards.
  static const double _cardGap = 10;

  /// Height of the caption row the bank selector sits in.
  static const double _headerHeight = 33;

  /// The vertical rhythm of this tab, as drawn: one gap between everything.
  static const double _gap = 14;

  int _bankOf(ControlState state) => _bank ?? state.activeBank;

  PedalBindingKey? _keyFor(PedalButton button, ControlState state) {
    if (PedalBindingKey.unbindable.contains(button)) return null;
    return PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? _bankOf(state) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Watched, not read: the cards, the rows and the check in the assign list
    // all render the live binding set, so every edit has to reach them.
    final cubit = context.watch<ControlCubit>();
    final state = cubit.state;
    final bank = _bankOf(state);
    final selected = _selected;

    return KeyedSubtree(
      key: const Key('pedal_tray_body'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: _gap),
            ConsoleGroupLabel(l10n.controlTransportGroup),
            const SizedBox(height: _gap),
            SizedBox(
              height: _cardHeight,
              child: Row(
                children: [
                  for (final (index, button) in kTransportSwitches.indexed) ...[
                    if (index > 0) const SizedBox(width: _cardGap),
                    Expanded(
                      child: _SwitchCard(
                        key: Key('pedal_switch_${button.name}'),
                        button: button,
                        binding: _bindingFor(state, button, bank),
                        selected: selected == button,
                        onTap: () => _select(button, state),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: _gap),
            SizedBox(
              height: _headerHeight,
              child: Row(
                children: [
                  ConsoleGroupLabel(l10n.controlTrackGroup),
                  const SizedBox(width: _gap),
                  ConsoleMiniToggle<int>(
                    key: const Key('pedal_bank'),
                    selected: bank,
                    segments: [
                      for (var b = 0; b < PedalBindingKey.bankCount; b++)
                        ConsoleSegment(
                          value: b,
                          label: l10n.controlBankLabel(
                            String.fromCharCode(65 + b),
                          ),
                        ),
                    ],
                    onChanged: (next) => setState(() => _bank = next),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _gap),
            ConsoleCard(
              children: [
                for (final (index, button) in kTrackSwitches.indexed)
                  _trackRow(
                    context,
                    state: state,
                    button: button,
                    bank: bank,
                    last: index == kTrackSwitches.length - 1,
                  ),
              ],
            ),
            // Always in the tree so the assign list grows the face open and
            // shrinks it shut, rather than appearing between two frames under
            // a list that jumps.
            ConsoleExpansion(
              key: const Key('pedal_assign_slot'),
              expanded: selected != null,
              child: selected == null
                  ? const SizedBox(width: double.infinity)
                  : _assignSection(context, cubit, selected, bank),
            ),
          ],
        ),
      ),
    );
  }

  PedalBinding? _bindingFor(ControlState state, PedalButton button, int bank) {
    final key = PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? bank : null,
    );
    return state.bindings.bindings.where((b) => b.key == key).firstOrNull;
  }

  void _select(PedalButton button, ControlState state) => setState(() {
    if (_selected == button) {
      _selected = null;
      return;
    }
    _selected = button;
    _showEffects = false;
    // Seed from the plate's own bank ONCE, so the first thing edited is the
    // bank the performer is standing in — and then never again. Re-seeding on
    // every selection snapped the list back to the pedal's bank the instant a
    // switch was tapped, which made the other bank's four switches literally
    // unselectable: you could move the toggle, but not then pick a row.
    _bank ??= state.activeBank;
  });

  Widget _trackRow(
    BuildContext context, {
    required ControlState state,
    required PedalButton button,
    required int bank,
    required bool last,
  }) {
    final l10n = context.l10n;
    final surface = context.surface;
    final looper = context.read<LooperRepository>();
    final trackNames = context.watch<TracksCubit>().state.names;
    final binding = _bindingFor(state, button, bank);
    final target = binding?.decodeTarget();
    final resolves = target != null && looper.bindingResolves(target);
    final open = _selected == button;

    return ConsoleRow(
      key: Key('pedal_switch_${button.name}'),
      title: pedalSwitchLabel(l10n, button, bank),
      value: switch ((binding, resolves)) {
        (null, _) => l10n.controlUnassigned,
        (_, false) => l10n.controlTargetMissing,
        _ => bindingTargetLabel(l10n, trackNames, target!),
      },
      // A binding whose target is gone takes the warning tone. Drawing it in
      // the muted grey of "unassigned" would state a different and wrong fact:
      // one switch does nothing because nobody asked it to, the other because
      // what it was asked to do no longer exists.
      valueColor: switch ((binding, resolves)) {
        (null, _) => surface.textMuted,
        (_, false) => surface.warning,
        _ => surface.textSecondary,
      },
      expanded: open,
      fill: open ? surface.accentSurface : null,
      showDivider: !last,
      onTap: () => _select(button, state),
    );
  }

  /// The caption and the target list for the selected switch.
  Widget _assignSection(
    BuildContext context,
    ControlCubit cubit,
    PedalButton button,
    int bank,
  ) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    final state = cubit.state;
    final key = _keyFor(button, state);
    final legend = pedalSwitchLegend(l10n, button, bank);

    // Edit the set IN FORCE, not the globals: a loaded session's remap
    // overrides the globals wholesale (A12), so editing globals while one is
    // active would write to a set that never dispatches.
    final editing = state.bindings;
    final binding = key == null
        ? null
        : editing.bindings.where((b) => b.key == key).firstOrNull;
    final current = binding?.decodeTarget();

    // ...and write it back through the GLOBAL set, always, PROMOTING a session
    // remap in the process. That is the full-screen plate's existing rule, and
    // two surfaces editing one binding must not disagree about where the edit
    // lands.
    Future<void> write(PedalBindingSet next) async {
      if (state.sessionBindings.isNotEmpty) {
        cubit.applySessionBindings(PedalBindingSet.empty);
      }
      await cubit.setGlobalBindings(next);
    }

    final targets = looper.availableBindingTargets();
    final chains = targets.whereType<FxChainTarget>().toList();
    final slots = targets.whereType<FxSlotTarget>().toList();
    final listed = <FxBindingTarget>[...chains, if (_showEffects) ...slots];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: _gap),
        ConsoleGroupLabel(
          PedalBindingKey.isBankKeyed(button)
              ? l10n.controlAssignGroup(
                  legend,
                  String.fromCharCode(65 + bank),
                )
              : l10n.controlAssignGroupPlain(legend),
        ),
        const SizedBox(height: _gap),
        if (listed.isEmpty)
          ConsoleEmptyCard(message: l10n.pedalAssignNoTargets)
        else
          ConsoleCard(
            children: [
              for (final (index, target) in listed.indexed)
                _targetRow(
                  context,
                  target: target,
                  current: current,
                  looper: looper,
                  onTap: key == null
                      ? null
                      : () => unawaited(
                          write(
                            // Tapping the target a switch already holds
                            // clears it. The check IS this row's on-state, and
                            // the drawn surface offers no other way back to
                            // "unassigned".
                            target == current
                                ? editing.without(key)
                                : editing.withBinding(
                                    binding?.copyWith(
                                          target: target.canonicalString(),
                                        ) ??
                                        PedalBinding(
                                          key: key,
                                          target: target.canonicalString(),
                                        ),
                                  ),
                          ),
                        ),
                  last: index == listed.length - 1,
                ),
              _EffectsToggle(
                key: const Key('pedal_show_effects'),
                showing: _showEffects,
                onTap: () => setState(() => _showEffects = !_showEffects),
              ),
            ],
          ),
      ],
    );
  }

  Widget _targetRow(
    BuildContext context, {
    required FxBindingTarget target,
    required FxBindingTarget? current,
    required LooperRepository looper,
    required VoidCallback? onTap,
    required bool last,
  }) {
    final l10n = context.l10n;
    final surface = context.surface;
    final chosen = target == current;
    final trackNames = context.watch<TracksCubit>().state.names;
    final stage = fxStageLabel(l10n, trackNames, target.address);
    return ConsoleRow(
      key: Key('pedal_target_${target.canonicalString()}'),
      title: switch (target) {
        FxChainTarget() => bindingTargetLabel(l10n, trackNames, target),
        // Named by its own effect rather than by repeating the chain above
        // it, which the row already says at its trailing edge.
        FxSlotTarget() =>
          fxSlotName(looper, target) ??
              bindingTargetLabel(l10n, trackNames, target),
      },
      titleColor: target is FxSlotTarget ? surface.textSecondary : null,
      state: switch (target) {
        FxChainTarget() => stage,
        FxSlotTarget() => l10n.controlEffectIn(stage),
      },
      valueColor: chosen ? surface.accent : surface.textMuted,
      indented: target is FxSlotTarget,
      // Nothing in this list opens — every row acts on the tap — so the
      // gutter a disclosure marker would reserve is not kept either.
      showDisclosure: false,
      mark: chosen
          ? const ConsoleCheck(key: Key('pedal_target_current'))
          : null,
      showDivider: !last,
      onTap: onTap,
    );
  }
}

/// One transport switch: its cap legend over what it is bound to.
class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.button,
    required this.binding,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final PedalButton button;
  final PedalBinding? binding;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final looper = context.read<LooperRepository>();
    final trackNames = context.watch<TracksCubit>().state.names;
    final target = binding?.decodeTarget();
    final resolves = target != null && looper.bindingResolves(target);
    // Transport switches only — a track switch is a row, and its name depends
    // on the bank a card has no business knowing about.
    final legend = pedalButtonLegend(button);
    final label = switch ((binding, resolves)) {
      (null, _) => l10n.controlUnassigned,
      (_, false) => l10n.controlTargetMissing,
      _ => bindingTargetLabel(l10n, trackNames, target!),
    };

    return FocusableTapTarget(
      onTap: onTap,
      selected: selected,
      semanticLabel: '$legend, $label',
      borderRadius: ConsoleCard.radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ConsoleCard.radius),
        child: AnimatedContainer(
          duration: consoleMotion(context),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            // The same accent tint the selected track row carries: one mark
            // for "this is the switch you are editing", wherever it is drawn.
            color: selected ? surface.accentSurface : surface.cardHigh,
            borderRadius: BorderRadius.circular(ConsoleCard.radius),
            border: Border.all(color: surface.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                legend,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: surface.textMuted,
                  fontFamily: SurfaceTheme.monoFont,
                  fontSize: 12,
                  height: 1.17,
                  letterSpacing: 0.96,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: switch ((binding, resolves)) {
                    (null, _) => surface.textMuted,
                    (_, false) => surface.warning,
                    _ => surface.textPrimary,
                  },
                  fontSize: 16,
                  height: 1.25,
                  leadingDistribution: TextLeadingDistribution.even,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The assign list's footer: one tap deeper, to the individual effect slots.
class _EffectsToggle extends StatelessWidget {
  const _EffectsToggle({
    required this.showing,
    required this.onTap,
    super.key,
  });

  final bool showing;
  final VoidCallback onTap;

  /// Height of the footer row — shorter than a list row, because it is not
  /// one: it changes what the list contains rather than being a thing in it.
  static const double height = 46;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final label = showing ? l10n.controlHideEffects : l10n.controlShowEffects;
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: surface.line)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: surface.textMuted,
              fontSize: 14,
              height: 1.21,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ),
    );
  }
}
