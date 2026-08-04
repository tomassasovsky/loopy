import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_chain_lookup.dart';

/// Resolves a typed [ControlValueTarget] against the live rig — the app-side
/// half of the continuous binding model, and the twin of part 6b's
/// [FxBindingResolver] for values rather than `enabled` flags (VGV).
///
/// This is the ONLY place a continuous mapping meets `looper_repository`, which
/// is what keeps `controller_repository` free of a looper dependency: it
/// carries mappings as opaque strings, `ControlCubit` decodes them, and this
/// resolver turns the decoded target into a parameter / volume / gain write.
///
/// ## Unresolvable targets go inert (A9)
///
/// Every method returns `null` / `false` rather than guessing when the target
/// does not name something that exists — a chain the rig has not configured, a
/// `slotId` no longer in the chain, a parameter index past the effect type's
/// own list. It NEVER falls back to the containing chain or to whatever now
/// sits at the old position: an expression pedal bound to a filter cutoff must
/// not start sweeping the delay that replaced it. A stale mapping is a no-op,
/// and its row says so.
extension ControlValueResolver on LooperRepository {
  /// Every value target the live rig can currently offer, in signal order:
  /// each configured chain's built-in effects with one entry per parameter,
  /// then the track volumes, then master gain.
  ///
  /// Only slots carrying a stable `slotId` are offered — an entry without one
  /// cannot be re-found after a reorder (A9). Hosted plugins are not offered:
  /// their parameters are addressed by plugin-assigned id rather than position
  /// and have no setter at every stage, so v1 leaves them to the on-screen
  /// controls.
  List<ControlValueTarget> availableValueTargets() {
    final targets = <ControlValueTarget>[];
    void add(FxAddress address, List<TrackEffect> entries) {
      for (final fx in entries) {
        final slotId = fx.slotId;
        if (slotId == null || fx is! BuiltInEffect) continue;
        for (var param = 0; param < fx.type.params.length; param++) {
          targets.add(
            FxParamTarget(address: address, slotId: slotId, param: param),
          );
        }
      }
    }

    for (final input in allMonitors().keys.toList()..sort()) {
      add(FxAddress(stage: FxStage.input, index: input), monitorEffects(input));
    }
    final laneKeys = allLaneChains().keys.toList()
      ..sort(
        (a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
      );
    for (final key in laneKeys) {
      add(
        FxAddress(stage: FxStage.loop, index: key.$1, lane: key.$2),
        laneEffects(key.$1, key.$2),
      );
    }
    for (final channel in allTrackChains().keys.toList()..sort()) {
      add(
        FxAddress(stage: FxStage.track, index: channel),
        trackEffects(channel),
      );
    }
    add(const FxAddress(stage: FxStage.master), masterEffects);
    for (final track in state.tracks) {
      targets.add(TrackVolumeTarget(track.channel));
    }
    // The master output always exists, so it is always offerable.
    targets.add(const MasterGainTarget());
    return targets;
  }

  /// Whether [target] names something that exists in the live rig.
  bool valueTargetResolves(ControlValueTarget target) => switch (target) {
    FxParamTarget() => _paramSlot(target) != null,
    TrackVolumeTarget(:final channel) =>
      channel >= 0 && channel < state.tracks.length,
    MasterGainTarget() => true,
  };

  /// Writes [value] (normalized `0..1`) to [target]. A no-op returning `false`
  /// when the target does not resolve, so a caller can skip the work a no-op
  /// would not need.
  bool writeValueTarget(ControlValueTarget target, double value) {
    final clamped = value.clamp(0.0, 1.0);
    switch (target) {
      case FxParamTarget(:final address, :final param):
        final slot = _paramSlot(target);
        if (slot == null) return false;
        switch (address.stage) {
          case FxStage.input:
            setMonitorEffectParam(
              input: address.index,
              index: slot.index,
              param: param,
              value: clamped,
            );
          case FxStage.loop:
            setLaneEffectParam(
              channel: address.index,
              // Non-null: `_paramSlot` already rejected a lane-less Loop
              // address, so this branch is unreachable without one.
              lane: address.lane!,
              index: slot.index,
              param: param,
              value: clamped,
            );
          case FxStage.track:
            setTrackEffectParam(
              channel: address.index,
              index: slot.index,
              param: param,
              value: clamped,
            );
          case FxStage.master:
            setMasterEffectParam(
              index: slot.index,
              param: param,
              value: clamped,
            );
        }
        return true;
      case TrackVolumeTarget(:final channel):
        if (channel < 0 || channel >= state.tracks.length) return false;
        setVolume(clamped, channel: channel);
        return true;
      case MasterGainTarget():
        setMasterGain(clamped);
        return true;
    }
  }

  /// The CURRENT position and entry [target] names, or `null` when the chain,
  /// the slot, or the parameter index is gone (A9).
  ({int index, BuiltInEffect effect})? _paramSlot(FxParamTarget target) {
    final entries = chainEntriesAt(target.address);
    if (entries == null) return null;
    for (var i = 0; i < entries.length; i++) {
      final fx = entries[i];
      if (fx.slotId != target.slotId) continue;
      if (fx is! BuiltInEffect) return null;
      if (target.param < 0 || target.param >= fx.type.params.length) {
        return null;
      }
      return (index: i, effect: fx);
    }
    return null;
  }
}
