import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/model/interaction_mode.dart';
import 'package:loopy/pedal/view/pedal_plate.dart';
import 'package:loopy/theme/page_transitions.dart';
import 'package:loopy/theme/theme.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Opens the pedal-assignment surface as a full-screen page.
///
/// Re-provides what the page drives into the pushed route — [ControlCubit]
/// (the binding owner) and the [LooperRepository] the target picker enumerates
/// from — the same way `showSignalPage` re-provides its own, since a pushed
/// route does not inherit the caller's providers.
Future<void> showPedalAssignmentPage(BuildContext context) {
  final control = context.read<ControlCubit>();
  final looper = context.read<LooperRepository>();
  return Navigator.of(context).push(
    desktopPageRoute<void>(
      (_) => MultiBlocProvider(
        providers: [BlocProvider.value(value: control)],
        child: RepositoryProvider<LooperRepository>.value(
          value: looper,
          child: const PedalAssignmentPage(),
        ),
      ),
    ),
  );
}

/// Names [target] for the picker and the assignment rows.
///
/// A pure function of the target and the localizations, so the same label
/// reaches the row, the picker entry, and the Semantics announcement — three
/// spellings of one target would read as three different bindings.
String bindingTargetLabel(AppLocalizations l10n, FxBindingTarget target) {
  final address = target.address;
  final stage = switch (address.stage) {
    FxStage.input => l10n.pedalAssignStageInput(address.index),
    FxStage.loop => l10n.pedalAssignStageLoop(address.index, address.lane ?? 0),
    FxStage.track => l10n.pedalAssignStageTrack(address.index),
    FxStage.master => l10n.pedalAssignStageMaster,
  };
  return switch (target) {
    FxChainTarget() => l10n.pedalAssignChainTarget(stage),
    // The slot id is the only stable name an effect has here — the effect
    // TYPE can repeat within one chain, so it could not identify which slot
    // the binding points at.
    FxSlotTarget(:final slotId) => '$stage · $slotId',
  };
}

/// The screen where footswitches are remapped onto FX targets (part 6b).
///
/// Composes part 6a's presentational `PedalPlate`: tapping a footswitch on the
/// plate selects it (the widget's injected `selected` set draws the
/// highlight), and the editor below edits that switch's binding. MODE and Bank
/// are selectable — so the user gets an explanation rather than an inert
/// switch — but never offered a target (B12).
class PedalAssignmentPage extends StatefulWidget {
  /// Creates a [PedalAssignmentPage].
  const PedalAssignmentPage({super.key});

  @override
  State<PedalAssignmentPage> createState() => _PedalAssignmentPageState();
}

class _PedalAssignmentPageState extends State<PedalAssignmentPage> {
  PedalButton? _selected;

  /// Which bank the selected TRACK button is being assigned for (A3);
  /// irrelevant for every other control.
  int _bank = 0;

  PedalBindingKey? get _key {
    final button = _selected;
    if (button == null) return null;
    if (PedalBindingKey.unbindable.contains(button)) return null;
    return PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? _bank : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    // Rebuild on every binding edit: the plate's assigned markers and the
    // editor below both read the live set.
    final cubit = context.watch<ControlCubit>();

    return Scaffold(
      backgroundColor: surface.background,
      appBar: AppBar(title: Text(l10n.pedalAssignTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n.pedalAssignIntro,
            style: TextStyle(color: surface.textSecondary),
          ),
          const SizedBox(height: 16),
          _PlatePicker(
            selected: _selected,
            onSelect: (button) => setState(() {
              _selected = button;
              if (PedalBindingKey.isBankKeyed(button)) {
                // Follow the plate's own bank so the row being edited is the
                // one the highlighted switch would act on.
                _bank = cubit.state.activeBank;
              }
            }),
          ),
          const SizedBox(height: 16),
          _Editor(
            selected: _selected,
            bindingKey: _key,
            bank: _bank,
            onBank: (bank) => setState(() => _bank = bank),
          ),
        ],
      ),
    );
  }
}

/// The plate, sized to the page, with the selected switch highlighted.
class _PlatePicker extends StatelessWidget {
  const _PlatePicker({required this.selected, required this.onSelect});

  final PedalButton? selected;
  final void Function(PedalButton button) onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mode = context.select<ControlCubit, InteractionMode>(
      (cubit) => cubit.state.mode,
    );
    final current = selected;
    return Semantics(
      label: current == null
          ? l10n.pedalAssignSelectPrompt
          : l10n.a11yPedalAssignSelected(current.name),
      child: AspectRatio(
        aspectRatio: 846 / 406.6,
        child: PedalPlate(
          // A DARK frame, not the live one: this plate is a diagram of the
          // hardware, and mirroring the running rig's LEDs here would read as
          // state the user can edit from this screen.
          frame: PedalStateFrame.blank(),
          // Select on the PRESS edge and swallow the release: a picker, not a
          // control surface — nothing here may reach the engine.
          onPress: (button, {required down}) {
            if (down) onSelect(button);
          },
          onTurn: (_) {},
          mode: mode,
          l10n: l10n,
          mainScreen: const SizedBox.shrink(),
          waveformScreen: const SizedBox.shrink(),
          onClose: () {},
          selected: {?current},
        ),
      ),
    );
  }
}

/// The binding editor for whichever switch is selected.
class _Editor extends StatelessWidget {
  const _Editor({
    required this.selected,
    required this.bindingKey,
    required this.bank,
    required this.onBank,
  });

  final PedalButton? selected;
  final PedalBindingKey? bindingKey;
  final int bank;
  final void Function(int bank) onBank;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final button = selected;

    if (button == null) {
      return _Notice(
        key: const Key('assign_prompt'),
        text: l10n.pedalAssignSelectPrompt,
      );
    }
    if (PedalBindingKey.unbindable.contains(button)) {
      return _Notice(
        key: const Key('assign_unbindable'),
        text: l10n.pedalAssignUnbindable,
        warning: true,
      );
    }

    final cubit = context.watch<ControlCubit>();
    final looper = context.read<LooperRepository>();
    final key = bindingKey!;
    // Edit the set IN FORCE, not the globals: a loaded session's remap
    // overrides the globals wholesale (A12), so editing globals while one is
    // active would silently write to a set that never dispatches — the user
    // rebinds a switch and stomping it still does the old thing.
    final editing = cubit.state.bindings;
    final binding = editing.bindings.where((b) => b.key == key).firstOrNull;
    final targets = looper.availableBindingTargets();
    final bound = binding?.decodeTarget();
    final resolves = bound != null && looper.bindingResolves(bound);

    // ...and write it back to whichever set that was. The session copy
    // persists with the next session save rather than to settings, which is
    // why it does not go through `setGlobalBindings`.
    Future<void> write(PedalBindingSet next) async {
      if (cubit.state.sessionBindings.isNotEmpty) {
        cubit.applySessionBindings(next);
        return;
      }
      await cubit.setGlobalBindings(next);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          button.name.toUpperCase(),
          style: TextStyle(
            color: surface.textPrimary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        if (PedalBindingKey.isBankKeyed(button)) ...[
          const SizedBox(height: 8),
          // Track buttons hold one binding PER BANK (A3) — the same switch in
          // the other bank already acts on a different channel, so it is a
          // separate assignment rather than a second reading of this one.
          SegmentedButton<int>(
            key: const Key('assign_bank'),
            segments: [
              for (var b = 0; b < PedalBindingKey.bankCount; b++)
                ButtonSegment(
                  value: b,
                  label: Text(
                    l10n.pedalAssignBankLabel(String.fromCharCode(65 + b)),
                  ),
                ),
            ],
            selected: {bank},
            onSelectionChanged: (s) => onBank(s.first),
          ),
        ],
        const SizedBox(height: 12),
        if (binding == null)
          _UnassignedRow(
            targets: targets,
            onPick: (target) => write(
              editing.withBinding(
                PedalBinding(key: key, target: target.canonicalString()),
              ),
            ),
          )
        else
          _BindingRow(
            binding: binding,
            targets: targets,
            resolves: resolves,
            onRebind: (target) => write(
              editing.withBinding(
                binding.copyWith(target: target.canonicalString()),
              ),
            ),
            onBehavior: (behavior) => write(
              editing.withBinding(binding.copyWith(behavior: behavior)),
            ),
            onClear: () => write(editing.without(key)),
          ),
      ],
    );
  }
}

/// A switch with no binding: the picker alone.
class _UnassignedRow extends StatelessWidget {
  const _UnassignedRow({required this.targets, required this.onPick});

  final List<FxBindingTarget> targets;
  final void Function(FxBindingTarget target) onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (targets.isEmpty) {
      return _Notice(
        key: const Key('assign_no_targets'),
        text: l10n.pedalAssignNoTargets,
      );
    }
    return Row(
      children: [
        Text(
          l10n.pedalAssignUnassigned,
          style: TextStyle(color: surface.textTertiary),
        ),
        const SizedBox(width: 12),
        _TargetPicker(targets: targets, current: null, onPick: onPick),
      ],
    );
  }
}

/// One assignment: its target, its behavior, and the rebind / clear actions.
class _BindingRow extends StatelessWidget {
  const _BindingRow({
    required this.binding,
    required this.targets,
    required this.resolves,
    required this.onRebind,
    required this.onBehavior,
    required this.onClear,
  });

  final PedalBinding binding;
  final List<FxBindingTarget> targets;

  /// Whether the bound target still exists in the live rig. A `false` here
  /// renders the stale treatment (R25) — the entry is PRESERVED either way.
  final bool resolves;

  final void Function(FxBindingTarget target) onRebind;
  final void Function(BindingBehavior behavior) onBehavior;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final target = binding.decodeTarget();
    final label = !resolves || target == null
        ? l10n.pedalAssignStale
        : bindingTargetLabel(l10n, target);

    return Semantics(
      label: l10n.a11yPedalAssignRow(binding.key.button.name, label),
      child: Container(
        key: const Key('assign_row'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: surface.cardHigh,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            // The established missing-target convention (R25): the same
            // tertiary outline the plugin placeholder card uses, so a broken
            // binding reads like every other unresolved entry in the app.
            color: resolves
                ? surface.line
                : surface.textTertiary.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (!resolves) ...[
                  Icon(
                    Icons.warning_amber_rounded,
                    key: const Key('assign_stale_glyph'),
                    size: 16,
                    color: surface.warning,
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: resolves
                          ? surface.textPrimary
                          : surface.textTertiary,
                    ),
                  ),
                ),
                _TargetPicker(
                  targets: targets,
                  current: resolves ? target : null,
                  onPick: onRebind,
                  label: l10n.pedalAssignRebind,
                ),
                const SizedBox(width: 4),
                TextButton(
                  key: const Key('assign_clear'),
                  onPressed: onClear,
                  child: Text(l10n.pedalAssignClear),
                ),
              ],
            ),
            if (!resolves) ...[
              const SizedBox(height: 6),
              Text(
                l10n.pedalAssignStaleDetail,
                key: const Key('assign_stale_detail'),
                style: TextStyle(color: surface.textTertiary, fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              l10n.pedalAssignBehavior,
              style: TextStyle(color: surface.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SegmentedButton<BindingBehavior>(
              key: const Key('assign_behavior'),
              segments: [
                ButtonSegment(
                  value: BindingBehavior.toggle,
                  label: Text(l10n.pedalAssignToggle),
                  tooltip: l10n.pedalAssignToggleHint,
                ),
                ButtonSegment(
                  value: BindingBehavior.momentary,
                  label: Text(l10n.pedalAssignMomentary),
                  tooltip: l10n.pedalAssignMomentaryHint,
                ),
              ],
              selected: {binding.behavior},
              onSelectionChanged: (s) => onBehavior(s.first),
            ),
          ],
        ),
      ),
    );
  }
}

/// The chain/effect picker, shared by the unassigned and rebind paths so both
/// offer exactly the same list.
class _TargetPicker extends StatelessWidget {
  const _TargetPicker({
    required this.targets,
    required this.current,
    required this.onPick,
    this.label,
  });

  final List<FxBindingTarget> targets;
  final FxBindingTarget? current;
  final void Function(FxBindingTarget target) onPick;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<FxBindingTarget>(
      key: const Key('assign_target_picker'),
      tooltip: l10n.pedalAssignTarget,
      onSelected: onPick,
      itemBuilder: (context) => [
        for (final target in targets)
          PopupMenuItem(
            value: target,
            child: Text(bindingTargetLabel(l10n, target)),
          ),
      ],
      child: Text(label ?? l10n.pedalAssignTarget),
    );
  }
}

/// A plain explanatory block — the "nothing selected" and "not remappable"
/// states, which are information rather than an editable row.
class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.warning = false, super.key});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: surface.line),
      ),
      child: Row(
        children: [
          if (warning) ...[
            Icon(
              Icons.lock_outline_rounded,
              size: 16,
              color: surface.textTertiary,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(text, style: TextStyle(color: surface.textSecondary)),
          ),
        ],
      ),
    );
  }
}
