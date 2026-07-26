/// Normalizes a raw channel string to `experimental` or `production`.
///
/// Anything other than (case-insensitive, trimmed) `experimental` becomes
/// `production`, so a typo in a marker file never points the device at a
/// non-existent channel tree.
String normalizeUpdateChannel(String raw) {
  final value = raw.trim().toLowerCase();
  return value == 'experimental' ? 'experimental' : 'production';
}
