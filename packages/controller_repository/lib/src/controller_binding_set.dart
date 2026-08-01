import 'dart:convert';

import 'package:controller_repository/src/controller_binding.dart';
import 'package:controller_repository/src/controller_input.dart';
import 'package:equatable/equatable.dart';

/// Every external-MIDI mapping the rig carries: at most one binding per
/// (control, target) pair, with fan-out and many-to-one both allowed.
///
/// Pure data — no engine, looper or Flutter dependency — so the same value is
/// the settings payload (`controller.mappings`, global-only in v1) and the
/// thing `ControllerRepository` resolves inputs against.
///
/// ## Why global-only (R19)
///
/// Expression hardware is per-RIG, not per-song: the pedal plugged into this
/// machine is the same one whatever session is loaded, and a session that
/// carried its own CC map would either fight the rig it is opened on or stop
/// being portable across machines. So the whole set lives in one settings blob
/// and sessions never carry a copy — a deliberate divergence from the pedal
/// remap, whose per-session override (A12) exists because the pedal's own
/// layout IS part of an arrangement.
class ControllerBindingSet extends Equatable {
  /// Creates a set from [bindings], keeping the LAST entry for a repeated
  /// (control, target) pair.
  factory ControllerBindingSet(Iterable<ControllerBinding> bindings) {
    final byKey = <(MappingTrigger, String), ControllerBinding>{};
    for (final binding in bindings) {
      byKey[binding.key] = binding;
    }
    return ControllerBindingSet._(List.unmodifiable(byKey.values));
  }

  const ControllerBindingSet._(this._bindings);

  /// Rebuilds a set from its [encode] string.
  ///
  /// Never throws and never returns null: an unparseable blob, a non-list
  /// payload, or an entry that does not describe a binding all degrade to the
  /// bindings that DID decode (possibly none). External control is a layer over
  /// a rig that already works without it — losing the map must never be able to
  /// block a boot.
  factory ControllerBindingSet.decode(String encoded) {
    if (encoded.isEmpty) return empty;
    final Object? raw;
    try {
      raw = jsonDecode(encoded);
    } on FormatException {
      return empty;
    }
    if (raw is! List) return empty;
    return ControllerBindingSet([
      for (final entry in raw)
        if (entry is Map<String, dynamic>) ?ControllerBinding.fromJson(entry),
    ]);
  }

  /// The set with no mappings — external MIDI drives nothing.
  static const ControllerBindingSet empty = ControllerBindingSet._(
    <ControllerBinding>[],
  );

  final List<ControllerBinding> _bindings;

  /// Every binding, in insertion order (the order rows are shown and encoded).
  List<ControllerBinding> get bindings => _bindings;

  /// Whether any control carries a mapping.
  bool get isEmpty => _bindings.isEmpty;

  /// Whether at least one control carries a mapping.
  bool get isNotEmpty => _bindings.isNotEmpty;

  /// How many mappings the set holds.
  int get length => _bindings.length;

  /// Every binding [input] drives, in set order — more than one when the same
  /// control fans out to several targets (B8).
  List<ControllerBinding> matching(RawControllerInput input) => [
    for (final binding in _bindings)
      if (binding.trigger.matches(input)) binding,
  ];

  /// Whether any binding other than [except] is already keyed to [trigger] —
  /// what the learn flow asks before it replaces an existing mapping.
  bool isTriggerBound(MappingTrigger trigger, {ControllerBinding? except}) =>
      _bindings.any((b) => b.trigger == trigger && b != except);

  /// Returns a copy with [binding] added, or replacing the one on its
  /// (control, target) key.
  ControllerBindingSet withBinding(ControllerBinding binding) =>
      ControllerBindingSet([..._bindings, binding]);

  /// Returns a copy with [binding] replaced in place by [next], preserving row
  /// order. Adds [next] when [binding] is not in the set.
  ControllerBindingSet replace(
    ControllerBinding binding,
    ControllerBinding next,
  ) {
    if (!_bindings.contains(binding)) return withBinding(next);
    return ControllerBindingSet([
      for (final entry in _bindings)
        if (entry == binding) next else entry,
    ]);
  }

  /// Returns a copy with [binding] removed. An unknown binding is a no-op.
  ControllerBindingSet without(ControllerBinding binding) =>
      ControllerBindingSet(_bindings.where((b) => b != binding));

  /// Returns a copy with every OTHER binding on [trigger] removed — the
  /// learn flow's replace-after-confirm.
  ControllerBindingSet withoutTrigger(
    MappingTrigger trigger, {
    ControllerBinding? except,
  }) => ControllerBindingSet(
    _bindings.where((b) => b.trigger != trigger || b == except),
  );

  /// The canonical encoding — a JSON array of [ControllerBinding.toJson] maps
  /// in [bindings] order. Byte-stable for equal sets, so a save→load round-trip
  /// reproduces the blob exactly.
  String encode() => _bindings.isEmpty
      ? ''
      : jsonEncode([for (final b in _bindings) b.toJson()]);

  @override
  List<Object?> get props => [_bindings];
}
