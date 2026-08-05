import 'package:controller_repository/controller_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/fx_chain_lookup.dart';
import 'package:segno/l10n/l10n.dart';

/// How a binding's target and its control are NAMED, in one place.
///
/// Pure functions of the target and the localizations, so the same words reach
/// the picker entry, the row, and the Semantics announcement — three spellings
/// of one target would read as three different mappings. Shared by the pedal
/// assignment screen (part 6b) and the MIDI-learn section (part 7), which is
/// why they live next to the binding model rather than inside either feature.

/// Names a footswitch as the hardware is silk-screened, so the console and
/// the pedal agree about which switch is being talked about.
String pedalButtonLabel(AppLocalizations l10n, PedalButton button) =>
    switch (button) {
      PedalButton.recPlay => l10n.pedalButtonRecPlay,
      PedalButton.stop => l10n.pedalButtonStop,
      PedalButton.undo => l10n.pedalButtonUndo,
      PedalButton.clear => l10n.pedalButtonClear,
      PedalButton.mode => l10n.pedalButtonMode,
      PedalButton.bank => l10n.pedalButtonBank,
      PedalButton.track1 => l10n.pedalButtonTrack(1),
      PedalButton.track2 => l10n.pedalButtonTrack(2),
      PedalButton.track3 => l10n.pedalButtonTrack(3),
      PedalButton.track4 => l10n.pedalButtonTrack(4),
    };

/// Names the chain at [address] — its stage and position.
String fxStageLabel(AppLocalizations l10n, FxAddress address) =>
    switch (address.stage) {
      FxStage.input => l10n.pedalAssignStageInput(address.index),
      FxStage.loop => l10n.pedalAssignStageLoop(
        address.index,
        address.lane ?? 0,
      ),
      FxStage.track => l10n.pedalAssignStageTrack(address.index),
      FxStage.master => l10n.pedalAssignStageMaster,
    };

/// Names a discrete (`enabled`-flipping) [target] — one whole chain, or one
/// effect inside it.
String bindingTargetLabel(AppLocalizations l10n, FxBindingTarget target) {
  final stage = fxStageLabel(l10n, target.address);
  return switch (target) {
    FxChainTarget() => l10n.pedalAssignChainTarget(stage),
    // The slot id is the only stable name an effect has here — the effect TYPE
    // can repeat within one chain, so it could not identify which slot the
    // binding points at.
    FxSlotTarget(:final slotId) => '$stage · $slotId',
  };
}

/// Names a continuous (value-writing) [target].
///
/// [looper] is consulted for an FX parameter's own label, which only the live
/// chain knows; a target whose slot is gone falls back to the bare parameter
/// index rather than vanishing, since a stale row still has to say what it
/// used to drive.
String valueTargetLabel(
  AppLocalizations l10n,
  LooperRepository looper,
  ControlValueTarget target,
) => switch (target) {
  TrackVolumeTarget(:final channel) => l10n.midiLearnTargetVolume(channel),
  MasterGainTarget() => l10n.midiLearnTargetMaster,
  FxParamTarget(:final address, :final slotId, :final param) =>
    l10n.midiLearnTargetParam(
      fxStageLabel(l10n, address),
      slotId,
      _paramLabel(looper, target) ?? '#$param',
    ),
};

/// Names the CONTROL a binding is keyed to — the CC/note number and the
/// channel it was learned on.
String controlLabel(AppLocalizations l10n, MappingTrigger trigger) {
  // An omni trigger has no channel of its own; it is shown as channel 1, the
  // one a user reading their controller's display would see first. Learned
  // controller bindings always carry a channel, so this only covers a
  // hand-written mapping.
  final channel = (trigger.midiChannel ?? 0) + 1;
  return switch (trigger.kind) {
    ControllerSourceKind.midiCc => l10n.midiLearnCcControl(trigger.id, channel),
    ControllerSourceKind.midiNote => l10n.midiLearnNoteControl(
      trigger.id,
      channel,
    ),
  };
}

/// The live label of the parameter [target] names, or `null` when the chain,
/// the slot, or the parameter index is gone.
///
/// Goes through the SAME [FxChainLookup] the resolvers use, so a label can
/// never describe a chain the mapping does not actually resolve against — a
/// lane-less Loop address names nothing here exactly as it writes nothing
/// there (A9).
String? _paramLabel(LooperRepository looper, FxParamTarget target) {
  final entries = looper.chainEntriesAt(target.address);
  if (entries == null) return null;
  for (final fx in entries) {
    if (fx.slotId != target.slotId) continue;
    if (fx is! BuiltInEffect) return null;
    final params = fx.type.params;
    if (target.param < 0 || target.param >= params.length) return null;
    return params[target.param].label;
  }
  return null;
}
