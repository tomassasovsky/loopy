import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:loopy/control/binding/fx_binding_target.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// [BindingBehavior] — toggle vs momentary — is re-exported from
/// `controller_repository`, where part 7 moved it so a discrete MIDI CC and a
/// footswitch mean the SAME two things by the same names. Callers that import
/// this library for `PedalBinding` keep getting it from here.
export 'package:controller_repository/controller_repository.dart'
    show BindingBehavior;

/// Which control a binding is keyed to.
///
/// Track buttons are keyed PER BANK (A3) — `track1` in bank A and `track1` in
/// bank B are two independently bindable controls, because they already act on
/// two different channels. Every other button is keyed per-button, with a null
/// [bank].
///
/// `PedalBindingSet` drops a key on MODE or Bank (B12), so those two are never
/// remappable no matter what a persisted blob claims.
class PedalBindingKey extends Equatable {
  /// Creates a key on [button], within [bank] for a track button.
  const PedalBindingKey({required this.button, this.bank});

  /// Rebuilds a key from its [toJson] map, or `null` when the map does not
  /// describe a bindable control (unknown button, or a bank coordinate that
  /// disagrees with the button's own keying rule).
  static PedalBindingKey? fromJson(Map<String, dynamic> json) {
    final rawButton = json['button'];
    if (rawButton is! String) return null;
    PedalButton? button;
    for (final value in PedalButton.values) {
      if (value.name == rawButton) button = value;
    }
    if (button == null) return null;
    final rawBank = json['bank'];
    final bank = rawBank is num ? rawBank.toInt() : null;
    if (isBankKeyed(button)) {
      if (bank == null || bank < 0 || bank >= bankCount) return null;
      return PedalBindingKey(button: button, bank: bank);
    }
    // A stray bank on a per-button control is corruption rather than a
    // second key: honoring it would let one button hold two bindings the
    // assignment screen can never show side by side.
    if (bank != null) return null;
    return PedalBindingKey(button: button);
  }

  /// How many banks the plate has — mirrors `ControlState.bankCount`, kept
  /// local so the binding model stays pure data with no cubit dependency.
  static const int bankCount = 2;

  /// The track footswitches, the only per-bank-keyed controls (A3).
  static const Set<PedalButton> trackButtons = {
    PedalButton.track1,
    PedalButton.track2,
    PedalButton.track3,
    PedalButton.track4,
  };

  /// The controls that can never carry a binding (B12): MODE is the only way
  /// out of FX mode, and Bank is the only way to reach the other four track
  /// buttons. A binding on either could strand the performer in a mode with
  /// no exit, so the model refuses to hold one at all.
  static const Set<PedalButton> unbindable = {
    PedalButton.mode,
    PedalButton.bank,
  };

  /// Whether [button] is keyed per bank rather than per button.
  static bool isBankKeyed(PedalButton button) => trackButtons.contains(button);

  /// The control this binding is keyed to.
  final PedalButton button;

  /// The bank this key applies to — non-null exactly for a track button.
  final int? bank;

  /// Serializes this key to a JSON map; the bank is omitted when the button
  /// is not bank-keyed, never written as null.
  Map<String, dynamic> toJson() => {
    'button': button.name,
    if (bank != null) 'bank': bank,
  };

  @override
  List<Object?> get props => [button, bank];
}

/// One remap: pressing [key] acts on [target] with [behavior], instead of that
/// button's contextual FX-mode default.
///
/// The [target] rides as an opaque canonical-JSON string, NOT as a decoded
/// [FxBindingTarget] — that is what lets the whole set persist through
/// `pedal_repository` / the session blob without those layers gaining a looper
/// dependency (VGV). Decode at the point of use with [decodeTarget]; a `null`
/// there is a stale binding (the chain or slot it named is gone), which stomps
/// as a no-op with an unlit LED and shows in the assignment screen as a broken
/// row (R25).
///
/// ## Momentary capture/restore (B1)
///
/// A [BindingBehavior.momentary] press captures the target's CURRENT enabled
/// state and enables it; the release writes the captured state back. The
/// capture is a plain snapshot, so overlapping writers are LAST-WRITER-WINS: if
/// a UI toggle (or a second binding on the same target) changes the target
/// while the foot is down, the release still restores what THIS press saw, and
/// the other writer's change is overwritten. That is deliberate — the
/// alternative, reconciling concurrent intent, has no reading a performer could
/// predict from the pedal alone. Releasing always writes, so a held momentary
/// can never outlive its press; see `ControlCubit`'s single release-all point
/// for the cases where the release never arrives.
class PedalBinding extends Equatable {
  /// Creates a binding of [key] to [target].
  const PedalBinding({
    required this.key,
    required this.target,
    this.behavior = BindingBehavior.toggle,
  });

  /// Rebuilds a binding from its [toJson] map, or `null` when the map does
  /// not describe one (unusable key, or a missing/empty target).
  static PedalBinding? fromJson(Map<String, dynamic> json) {
    final key = PedalBindingKey.fromJson(json);
    if (key == null) return null;
    final target = json['target'];
    if (target is! String || target.isEmpty) return null;
    return PedalBinding(
      key: key,
      target: target,
      behavior: BindingBehavior.fromName(json['behavior'] as String?),
    );
  }

  /// The control this binding is keyed to.
  final PedalBindingKey key;

  /// The bound target as its canonical-JSON string (see the class doc).
  ///
  /// Kept even when it no longer resolves: a stale binding stays in the set so
  /// the assignment screen can offer rebind and clear on it, rather than
  /// vanishing and leaving the user to guess what they had bound (R25).
  final String target;

  /// Whether the press latches or is held.
  final BindingBehavior behavior;

  /// The decoded target, or `null` when the string no longer parses.
  FxBindingTarget? decodeTarget() => FxBindingTarget.tryParse(target);

  /// Returns a copy with the given fields replaced.
  PedalBinding copyWith({String? target, BindingBehavior? behavior}) =>
      PedalBinding(
        key: key,
        target: target ?? this.target,
        behavior: behavior ?? this.behavior,
      );

  /// Serializes this binding to a JSON map — the key's own fields, flattened,
  /// plus the target and behavior.
  Map<String, dynamic> toJson() => {
    ...key.toJson(),
    'target': target,
    'behavior': behavior.name,
  };

  @override
  List<Object?> get props => [key, target, behavior];
}
