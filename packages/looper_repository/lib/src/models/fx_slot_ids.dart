import 'dart:math';

import 'package:looper_repository/src/models/track_effect.dart';
import 'package:meta/meta.dart';

/// Mints stable per-slot effect ids (A9).
///
/// Identity ownership lives in `looper_repository`: every repository write
/// path that accepts a chain assigns a fresh id to any entry lacking one, via
/// [withMintedSlotIds]. The invariants (pinned by tests):
///
/// - unique within a session, never reused;
/// - preserved across `copyWith` / param edits / reorders (the id rides the
///   entry, and the repository never re-mints an entry that has one);
/// - stable across persist→restore (the id is part of the persisted entry);
/// - minted exactly once for legacy payloads (a pre-FX-v3 entry decodes with
///   a null id and receives one on its first repository write).
///
/// Ids are `<session-prefix>-<counter>`: the random per-process prefix keeps a
/// fresh mint from colliding with ids restored from an earlier session (whose
/// mints used a different prefix), and the monotonic counter guarantees
/// uniqueness within this session.
abstract final class SlotIds {
  static final Random _random = Random();
  static String _prefix = _newPrefix();
  static int _next = 0;

  static String _newPrefix() =>
      _random.nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0');

  /// Mints a fresh id, unique within this session and (by the random prefix)
  /// not reused from a prior one.
  static String mint() => '$_prefix-${_next++}';

  /// Restarts the sequence under a new random prefix. Test seam only — lets a
  /// test prove two "sessions" never hand out the same id.
  @visibleForTesting
  static void resetForTesting() {
    _prefix = _newPrefix();
    _next = 0;
  }
}

/// Returns [effects] with a fresh [TrackEffect.slotId] minted for every entry
/// that lacks one; entries that already carry an id are returned as-is (the
/// mint-once invariant). Call this at every repository write boundary.
List<TrackEffect> withMintedSlotIds(List<TrackEffect> effects) => [
  for (final fx in effects)
    if (fx.slotId != null) fx else _withSlotId(fx, SlotIds.mint()),
];

/// Returns [effects] with a fresh [TrackEffect.slotId] minted for EVERY entry,
/// replacing any existing ids. For inheritance copies (R13/A9): a take's
/// entries are new identities, so bindings on the source input chain must not
/// follow the copy.
List<TrackEffect> withFreshSlotIds(List<TrackEffect> effects) => [
  for (final fx in effects) _withSlotId(fx, SlotIds.mint()),
];

TrackEffect _withSlotId(TrackEffect fx, String id) => switch (fx) {
  BuiltInEffect() => fx.copyWith(slotId: id),
  PluginEffect() => fx.copyWith(slotId: id),
};
