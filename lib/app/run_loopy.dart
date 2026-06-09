import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/audio_bootstrap.dart';
import 'package:loopy/app/view/app.dart';
import 'package:loopy/bootstrap.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:settings_repository/settings_repository.dart';

/// Shared entrypoint for every flavor: routes the secondary waveform window,
/// otherwise wires the repositories, auto-starts the engine from the saved
/// audio config (showing the setup flow on a first run), and runs the [App].
Future<void> runLoopy(List<String> args) async {
  // A `multi_window` sub-window (the output waveform) is a separate Flutter
  // engine; it runs a lightweight app and owns no audio engine.
  if (args.isNotEmpty && args.first == 'multi_window') {
    runWaveformWindow(int.parse(args[1]));
    return;
  }

  // Settings are read before `runApp`, so the binding must be ready for the
  // shared_preferences platform channel.
  WidgetsFlutterBinding.ensureInitialized();

  // Hot restart resets Dart state while native sub-windows survive.
  await DesktopMultiWindowWaveformService.closeOrphanWindows();

  final repository = LooperRepository(engine: NativeAudioEngine());
  final controllerRepository = ControllerRepository(sources: const []);
  final settings = SettingsRepository(store: SharedPreferencesKeyValueStore());

  await settings.clear();

  final configured = await tryAutoStartEngine(
    repository: repository,
    settings: settings,
  );

  await bootstrap(
    () => App(
      repository: repository,
      controllerRepository: controllerRepository,
      settings: settings,
      waveformWindow: DesktopMultiWindowWaveformService(),
      needsSetup: !configured,
    ),
  );
}
