import 'package:path_provider/path_provider.dart';

/// Resolves the `sessions/` root under the app's documents folder — the parent
/// of every named-session bundle. Wired into the session repository by the
/// composition root so it can enumerate, save, rename, and delete named
/// sessions.
///
/// The legacy single `loopy_session/` bundle (if a previous version wrote one)
/// is a sibling of this root, so it is never enumerated as a named session.
Future<String> defaultSessionsRoot() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/sessions';
}

/// Resolves the `exports/` directory under the app's documents folder — where a
/// mixdown or per-track stems are written. A sibling of [defaultSessionsRoot],
/// so exported audio never appears in the session catalog.
Future<String> defaultExportDirectory() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/exports';
}
