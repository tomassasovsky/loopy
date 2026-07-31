import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// What a pedal binding points at: one whole chain, or one effect inside a
/// chain (A9).
///
/// ## Why this type lives app-side
///
/// The typed target and its resolution sit next to `ControlCubit` rather than
/// in `pedal_repository` / `controller_repository` (VGV-critical): those
/// packages carry bindings as opaque [canonicalString] values and gain NO
/// looper/engine dependency, so no second control-surface interpreter can grow
/// inside a repository package. `ControlCubit` stays the single dispatch point.
///
/// ## Canonical JSON
///
/// The encoding EXTENDS part 3a's [FxAddress] canonical form rather than
/// redeclaring it (R19): the address contributes its own fixed key order
/// (`stage`, `index`, `lane`), and an effect-level target appends exactly one
/// key, `slot`. A chain-level target adds nothing, so its string IS
/// [FxAddress.canonicalString]. Byte-stable in both cases, so plain string
/// equality is target identity.
///
/// This composes safely because [FxAddress.fromJson] ignores keys it does not
/// know (its additive-only contract) — the same map decodes as an address
/// there and as a slot target here.
sealed class FxBindingTarget extends Equatable {
  const FxBindingTarget();

  /// Parses a [canonicalString] back to a target, or `null` when [encoded] is
  /// not a decodable one.
  ///
  /// Never throws: bindings cross package boundaries and app restarts as bare
  /// strings, so a corrupt or hand-edited one must decode to `null` — which
  /// the caller renders as a stale binding — rather than taking down the
  /// control surface.
  static FxBindingTarget? tryParse(String encoded) {
    final Object? raw;
    try {
      raw = jsonDecode(encoded);
    } on FormatException {
      return null;
    }
    if (raw is! Map<String, dynamic>) return null;
    final address = FxAddress.fromJson(raw);
    if (address == null) return null;
    final slot = raw['slot'];
    if (slot == null) return FxChainTarget(address);
    // A present-but-unusable `slot` is corruption, not a chain target:
    // silently widening an effect binding to its whole chain would bypass far
    // more than the user asked for on the next stomp.
    if (slot is! String || slot.isEmpty) return null;
    return FxSlotTarget(address: address, slotId: slot);
  }

  /// The chain this target lives on — the whole target for a
  /// [FxChainTarget], the containing chain for a [FxSlotTarget].
  FxAddress get address;

  /// The byte-stable canonical serialization (see the class doc).
  String canonicalString();
}

/// A whole-chain target: the stomp flips that chain's `enabled` flag —
/// "disabled == dry through the bus" (R15).
final class FxChainTarget extends FxBindingTarget {
  /// Creates a chain-level target on [address].
  const FxChainTarget(this.address);

  @override
  final FxAddress address;

  @override
  String canonicalString() => address.canonicalString();

  @override
  List<Object?> get props => [address];
}

/// A single-effect target: the stomp flips one slot's `enabled` flag inside
/// the chain at [address].
///
/// Keyed by the stable [slotId] part 3a stamps on every entry, never by
/// position (A9) — inserting or reordering effects around a bound one must
/// leave the binding pointing at the SAME effect. When the slot is gone the
/// target goes inert; it never falls back to the chain or to a neighbouring
/// slot.
final class FxSlotTarget extends FxBindingTarget {
  /// Creates an effect-level target on [slotId] within [address]'s chain.
  const FxSlotTarget({required this.address, required this.slotId});

  @override
  final FxAddress address;

  /// The stable per-slot id (part 3a) of the bound effect.
  final String slotId;

  @override
  String canonicalString() => jsonEncode({...address.toJson(), 'slot': slotId});

  @override
  List<Object?> get props => [address, slotId];
}
