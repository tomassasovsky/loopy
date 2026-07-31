import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:loopy/control/binding/pedal_binding.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The whole remap: at most one [PedalBinding] per bindable control.
///
/// Pure data — no cubit, repository or engine dependency — so the same value
/// is the settings payload, the session blob payload, and the thing
/// `ControlCubit` dispatches against.
///
/// ## Invariants the constructor enforces
///
/// Bindings on MODE or Bank are DROPPED, not rejected loudly (B12). A
/// hand-edited settings string or a session bundle from a future build could
/// carry one, and refusing the whole set over it would cost the user every
/// other binding they made; dropping the one that cannot be honored keeps the
/// rest and matches how the rest of the persistence layer treats corruption.
///
/// ## Merge rule (A12)
///
/// [resolveAgainst] implements the pinned rule: a session with ANY bindings
/// overrides the global set WHOLESALE. There is no per-button merging — a
/// session either brings its own complete remap or defers entirely to the
/// globals. Per-button merging was rejected because a half-session/half-global
/// map is a layout no screen can show honestly, and the performer could not
/// predict which half a given switch came from.
class PedalBindingSet extends Equatable {
  /// Creates a set from [bindings], keeping the LAST entry for a repeated key
  /// and dropping any binding on an unbindable control.
  factory PedalBindingSet(Iterable<PedalBinding> bindings) {
    final byKey = <PedalBindingKey, PedalBinding>{};
    for (final binding in bindings) {
      if (PedalBindingKey.unbindable.contains(binding.key.button)) continue;
      byKey[binding.key] = binding;
    }
    return PedalBindingSet._(Map.unmodifiable(byKey));
  }

  const PedalBindingSet._(this._byKey);

  /// Rebuilds a set from its [encode] string.
  ///
  /// Never throws and never returns null: an unparseable blob, a non-list
  /// payload, or an entry that does not describe a binding all degrade to the
  /// bindings that DID decode (possibly none). A remap is an optional
  /// convenience layered over working contextual defaults — losing it must
  /// never be able to block a session load or a boot.
  factory PedalBindingSet.decode(String encoded) {
    if (encoded.isEmpty) return empty;
    final Object? raw;
    try {
      raw = jsonDecode(encoded);
    } on FormatException {
      return empty;
    }
    if (raw is! List) return empty;
    return PedalBindingSet([
      for (final entry in raw)
        if (entry is Map<String, dynamic>) ?PedalBinding.fromJson(entry),
    ]);
  }

  /// The set with no bindings — every button keeps its contextual default.
  static const PedalBindingSet empty = PedalBindingSet._(
    <PedalBindingKey, PedalBinding>{},
  );

  final Map<PedalBindingKey, PedalBinding> _byKey;

  /// Whether any control carries a binding — the (A12) merge discriminator.
  bool get isEmpty => _byKey.isEmpty;

  /// Whether at least one control carries a binding.
  bool get isNotEmpty => _byKey.isNotEmpty;

  /// How many controls carry a binding.
  int get length => _byKey.length;

  /// Every binding, ordered by control so the encoding is stable across
  /// rebuilds (a set that changed only in map iteration order must not look
  /// like an edit to the session's dirty tracking).
  List<PedalBinding> get bindings {
    final all = _byKey.values.toList()
      ..sort((a, b) {
        final button = a.key.button.index.compareTo(b.key.button.index);
        if (button != 0) return button;
        return (a.key.bank ?? -1).compareTo(b.key.bank ?? -1);
      });
    return List.unmodifiable(all);
  }

  /// The binding on [button] within [bank], or `null` when it is unbound.
  ///
  /// [bank] is consulted only for a bank-keyed control (A3), so a caller can
  /// pass the live bank unconditionally.
  PedalBinding? lookup(PedalButton button, {required int bank}) {
    final key = PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? bank : null,
    );
    return _byKey[key];
  }

  /// Returns a copy with [binding] added or replacing the one on its key. A
  /// binding on an unbindable control is dropped, per the class doc.
  PedalBindingSet withBinding(PedalBinding binding) =>
      PedalBindingSet([..._byKey.values, binding]);

  /// Returns a copy with the binding on [key] removed (the assignment
  /// screen's "clear" action). Unknown keys are a no-op.
  PedalBindingSet without(PedalBindingKey key) =>
      PedalBindingSet(_byKey.values.where((b) => b.key != key));

  /// The set that actually applies, given this as the GLOBAL set and
  /// [session] as the loaded session's own (A12).
  ///
  /// Wholesale: a non-empty [session] set wins entirely; otherwise the
  /// globals apply. Never merges the two.
  PedalBindingSet resolveAgainst(PedalBindingSet session) =>
      session.isNotEmpty ? session : this;

  /// The canonical encoding — a JSON array of [PedalBinding.toJson] maps in
  /// [bindings] order. Byte-stable for equal sets, so a save→load round-trip
  /// preserves the blob exactly and an unchanged set never looks dirty.
  String encode() =>
      _byKey.isEmpty ? '' : jsonEncode([for (final b in bindings) b.toJson()]);

  @override
  List<Object?> get props => [bindings];
}
