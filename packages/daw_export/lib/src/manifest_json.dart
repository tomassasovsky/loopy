/// Shared, tiny JSON-shape helpers for reading a decoded `performance.json`
/// map — used by both `manifest_reader.dart` and `fx_chains.dart`, which
/// otherwise each parse the same `armSnapshot`/`disarmSnapshot` shape for
/// two genuinely different outputs (track/clip layout vs. an FX-chain
/// summary). Factored out so the one thing they'd otherwise duplicate byte
/// for byte — "what does a tracks[] array look like" — can't silently drift
/// between the two.
library;

/// Returns `snapshot['tracks']` as a typed list, or an empty list if
/// `snapshot` isn't a `Map` or has no (or a non-list) `tracks` field —
/// tolerant of a missing/malformed `armSnapshot`/`disarmSnapshot` rather
/// than throwing.
List<Map<String, dynamic>> tracksOf(dynamic snapshot) {
  if (snapshot is! Map<String, dynamic>) return const [];
  final tracks = snapshot['tracks'];
  if (tracks is! List) return const [];
  return [for (final t in tracks) t as Map<String, dynamic>];
}
