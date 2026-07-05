import 'package:path_provider/path_provider.dart';

/// Resolves the single on-disk session bundle directory under the app's
/// documents folder. Shared by the flavor entrypoints.
///
/// Legacy: the named-session catalog uses [defaultSessionsRoot] instead. The
/// two are siblings, so this bundle is never enumerated as a named session.
Future<String> defaultSessionDirectory() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/loopy_session';
}

/// Resolves the `sessions/` root under the app's documents folder — the parent
/// of every named-session bundle. A sibling of [defaultSessionDirectory]'s
/// legacy `loopy_session/` bundle, which therefore never appears in the
/// catalog. Wired into the session repository by the composition root.
Future<String> defaultSessionsRoot() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/sessions';
}
