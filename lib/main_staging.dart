import 'package:controller_repository/controller_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/bootstrap.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:settings_repository/settings_repository.dart';

Future<void> main(List<String> args) async {
  // A `multi_window` sub-window (the output waveform) is a separate Flutter
  // engine; it runs a lightweight app and owns no audio engine.
  if (args.isNotEmpty && args.first == 'multi_window') {
    runWaveformWindow(int.parse(args[1]));
    return;
  }

  final repository = LooperRepository(engine: NativeAudioEngine());
  final controllerRepository = ControllerRepository(sources: const []);
  final settings = SettingsRepository(
    store: SharedPreferencesKeyValueStore(),
  );
  await bootstrap(
    () => App(
      repository: repository,
      controllerRepository: controllerRepository,
      settings: settings,
      waveformWindow: DesktopMultiWindowWaveformService(),
    ),
  );
}
