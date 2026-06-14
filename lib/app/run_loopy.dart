import 'package:controller_repository/controller_repository.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/audio_bootstrap.dart';
import 'package:loopy/app/monitor_migration.dart';
import 'package:loopy/app/view/app.dart';
import 'package:loopy/bootstrap.dart';
import 'package:loopy/session_directory.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:loopy/visualizer/waveform_window_args.dart';
import 'package:loopy/window/window_chrome.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Shared entrypoint for every flavor: routes the secondary waveform window,
/// otherwise wires the repositories, auto-starts the engine (from the saved
/// config or a first-run default), and runs the [App] straight on the looper.
Future<void> runLoopy(
  List<String> args, {
  AudioEngine Function()? createEngine,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  final windowController = await WindowController.fromCurrentEngine();
  if (WaveformWindowArgs.isWaveformWindow(windowController.arguments)) {
    await runWaveformWindow(windowController);
    return;
  }

  // Hot restart resets Dart state while native sub-windows survive.
  await DesktopMultiWindowWaveformService.closeOrphanWindows();

  await configureLoopyDesktopWindow();

  // One engine instance, shared by the looper (which owns its lifecycle) and
  // the session repository (which only reads/writes its loop PCM).
  final engine = createEngine?.call() ?? NativeAudioEngine();
  final repository = LooperRepository(engine: engine);
  final controllerRepository = ControllerRepository(sources: const []);
  final settings = SettingsRepository(store: SharedPreferencesKeyValueStore());
  final sessionRepository = SessionRepository(engine: engine);

  // One-time courtesy migration from the removed global passthrough monitor to
  // the per-input routing graph. Runs before the engine-start branch (and so on
  // the mock path and a first launch too), independent of whether a saved audio
  // config exists.
  await runMonitorMigration(settings);

  // Auto-start the engine and lands directly on the looper (no first-run gate).
  // The mock flavor opens a deterministic default config; the native flavor
  // auto-starts from the saved config or a first-run default and returns the
  // ASIO drivers enumerated at startup for the audio-setup picker cache.
  var asioDrivers = const <AudioDevice>[];
  if (engine is MockAudioEngine) {
    repository.startEngine(engine.defaultConfig);
  } else {
    final result = await tryAutoStartEngine(
      repository: repository,
      settings: settings,
    );
    asioDrivers = result.asioDrivers;
  }

  await bootstrap(
    () => App(
      repository: repository,
      controllerRepository: controllerRepository,
      settings: settings,
      waveformWindow: DesktopMultiWindowWaveformService(),
      sessionRepository: sessionRepository,
      sessionDirectory: defaultSessionDirectory,
      initialAsioDrivers: asioDrivers,
    ),
  );
}
