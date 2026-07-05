/// Folds [name] into a folder-safe session slug.
///
/// The stored name IS the slug (there is no separate persisted display name),
/// so it both sanitizes the input and is what the picker shows. It keeps
/// letters, digits, spaces, hyphens and underscores, turns every other
/// character into a space, then collapses internal whitespace runs and trims.
///
/// Returns `null` when nothing usable remains — empty, whitespace-only, or only
/// disallowed characters — which callers treat as an invalid name. Because the
/// fold is lossy, two distinct inputs can collapse to the same slug (e.g.
/// `"My Song!"` and `"My Song"`), which then collide on disk as one bundle.
String? sessionSlug(String name) {
  final slug = name
      .replaceAll(RegExp('[^A-Za-z0-9 _-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return slug.isEmpty ? null : slug;
}
