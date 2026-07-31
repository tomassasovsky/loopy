import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/binding/fx_binding_target.dart';

/// Resolves a typed [FxBindingTarget] against the live rig — the app-side
/// half of the binding model (VGV).
///
/// This is the ONLY place a binding meets `looper_repository`, which is what
/// keeps the repository packages free of a looper dependency: they carry
/// bindings as opaque strings, `ControlCubit` decodes them, and this resolver
/// turns the decoded target into the part 3a per-chain / per-slot `enabled`
/// calls.
///
/// ## Unresolvable targets go inert (A9)
///
/// Every method returns `null` / `false` rather than guessing when the target
/// does not name something that exists — a chain on a stage the rig has not
/// configured, or a [FxSlotTarget] whose `slotId` is no longer in the chain.
/// It NEVER falls back to the containing chain or to the slot that now sits at
/// the old position: a stomp bound to a reverb must not start bypassing the
/// delay that replaced it. A stale binding is a no-op with an unlit LED, and
/// the assignment screen shows it as broken (R25).
extension FxBindingResolver on LooperRepository {
  /// Every target the live rig can currently offer a binding, in signal
  /// order: each configured chain followed by its own slots.
  ///
  /// What the assignment screen's picker lists. Only slots carrying a stable
  /// `slotId` are offered — an entry without one cannot be re-found after a
  /// reorder, so binding to it would create a target that silently goes stale
  /// on the next edit (A9).
  List<FxBindingTarget> availableBindingTargets() {
    final targets = <FxBindingTarget>[];
    void add(FxAddress address, List<TrackEffect> entries) {
      targets.add(FxChainTarget(address));
      for (final fx in entries) {
        final slotId = fx.slotId;
        if (slotId != null) {
          targets.add(FxSlotTarget(address: address, slotId: slotId));
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
    // The Master insert always exists, so it is always offerable.
    add(const FxAddress(stage: FxStage.master), masterEffects);
    return targets;
  }

  /// The target's current `enabled` state, or `null` when it does not
  /// resolve.
  bool? bindingEnabled(FxBindingTarget target) {
    switch (target) {
      case FxChainTarget(:final address):
        return _chainEnabled(address);
      case FxSlotTarget(:final address, :final slotId):
        final index = _slotIndex(address, slotId);
        if (index == null) return null;
        return _chainEntries(address)![index].enabled;
    }
  }

  /// Whether [target] names something that exists in the live rig.
  bool bindingResolves(FxBindingTarget target) =>
      bindingEnabled(target) != null;

  /// Writes [enabled] to [target]. A no-op when the target does not resolve,
  /// or when it already holds that value.
  ///
  /// Returns whether anything was written, so a caller can skip the persist
  /// and the LED re-projection a no-op would not need.
  bool setBindingEnabled(FxBindingTarget target, {required bool enabled}) {
    if (bindingEnabled(target) != !enabled) return false;
    return switch (target) {
      FxChainTarget(:final address) => _setChainEnabled(
        address,
        enabled: enabled,
      ),
      FxSlotTarget(:final address, :final slotId) => _setSlotEnabled(
        address,
        slotId,
        enabled: enabled,
      ),
    };
  }

  /// The chain-level `enabled` flag at [address], or `null` when that chain
  /// does not exist in the rig.
  bool? _chainEnabled(FxAddress address) {
    if (_chainEntries(address) == null) return null;
    return switch (address.stage) {
      FxStage.input => monitorChainEnabled(address.index),
      FxStage.loop => laneChainEnabled(address.index, address.lane ?? 0),
      FxStage.track => trackChainEnabled(address.index),
      FxStage.master => masterChainEnvelope().chainEnabled,
    };
  }

  bool _setChainEnabled(FxAddress address, {required bool enabled}) {
    switch (address.stage) {
      case FxStage.input:
        setMonitorChainEnabled(input: address.index, enabled: enabled);
      case FxStage.loop:
        setLaneChainEnabled(
          channel: address.index,
          lane: address.lane ?? 0,
          enabled: enabled,
        );
      case FxStage.track:
        setTrackChainEnabled(channel: address.index, enabled: enabled);
      case FxStage.master:
        setMasterChainEnabled(enabled: enabled);
    }
    return true;
  }

  bool _setSlotEnabled(
    FxAddress address,
    String slotId, {
    required bool enabled,
  }) {
    final index = _slotIndex(address, slotId);
    if (index == null) return false;
    switch (address.stage) {
      case FxStage.input:
        setMonitorEffectEnabled(
          input: address.index,
          index: index,
          enabled: enabled,
        );
      case FxStage.loop:
        setLaneEffectEnabled(
          channel: address.index,
          lane: address.lane ?? 0,
          index: index,
          enabled: enabled,
        );
      case FxStage.track:
        setTrackEffectEnabled(
          channel: address.index,
          index: index,
          enabled: enabled,
        );
      case FxStage.master:
        setMasterEffectEnabled(index: index, enabled: enabled);
    }
    return true;
  }

  /// The chain's entries at [address], or `null` when the rig has no chain
  /// there at all.
  ///
  /// An EMPTY chain and a missing one are different: a configured monitor with
  /// no effects still resolves (its chain flag is real and stompable), while a
  /// stage the rig never configured does not. The per-stage accessors below
  /// already draw that line — they return an empty list for a configured
  /// stage and nothing for an absent one.
  List<TrackEffect>? _chainEntries(FxAddress address) {
    if (address.index < 0) return null;
    return switch (address.stage) {
      FxStage.input =>
        allMonitors().containsKey(address.index)
            ? monitorEffects(address.index)
            : null,
      FxStage.loop =>
        allLaneChains().containsKey((address.index, address.lane ?? 0))
            ? laneEffects(address.index, address.lane ?? 0)
            : null,
      FxStage.track =>
        allTrackChains().containsKey(address.index)
            ? trackEffects(address.index)
            : null,
      // There is exactly one Master insert and it always exists; a non-zero
      // index is a malformed address rather than a second one.
      FxStage.master => address.index == 0 ? masterEffects : null,
    };
  }

  /// The CURRENT position of [slotId] within [address]'s chain, or `null` when
  /// no entry carries that id — the indirection that makes a binding survive
  /// inserts and reorders (A9).
  int? _slotIndex(FxAddress address, String slotId) {
    final entries = _chainEntries(address);
    if (entries == null) return null;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].slotId == slotId) return i;
    }
    return null;
  }
}
