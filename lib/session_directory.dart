import 'package:path_provider/path_provider.dart';

/// Resolves the single on-disk session bundle directory under the app's
/// documents folder. Shared by the flavor entrypoints.
Future<String> defaultSessionDirectory() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/loopy_session';
}
