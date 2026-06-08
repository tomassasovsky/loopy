import 'package:controller_repository/controller_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/bootstrap.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:path_provider/path_provider.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

Future<void> main() async {
  // One engine instance, shared by the looper (which owns its lifecycle) and
  // the session repository (which only reads/writes its loop PCM).
  final engine = NativeAudioEngine();
  final repository = LooperRepository(engine: engine);
  final controllerRepository = ControllerRepository(sources: const []);
  final settings = SettingsRepository(
    store: SharedPreferencesKeyValueStore(),
  );
  final sessionRepository = SessionRepository(engine: engine);
  await bootstrap(
    () => App(
      repository: repository,
      controllerRepository: controllerRepository,
      settings: settings,
      sessionRepository: sessionRepository,
      sessionDirectory: _sessionDirectory,
    ),
  );
}

/// Resolves the single on-disk session bundle directory under app documents.
Future<String> _sessionDirectory() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/loopy_session';
}
