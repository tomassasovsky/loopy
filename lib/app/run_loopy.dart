import 'package:controller_repository/controller_repository.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';
import 'package:gpio_client/gpio_client.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/audio_bootstrap.dart';
import 'package:loopy/app/monitor_migration.dart';
import 'package:loopy/app/view/app.dart';
import 'package:loopy/bootstrap.dart';
import 'package:loopy/session_directory.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:loopy/visualizer/waveform_window_args.dart';
import 'package:loopy/window/window_chrome.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Shared entrypoint for every flavor: routes the secondary waveform window,
/// otherwise wires the repositories, auto-starts the engine (from the saved
/// config or a first-run default), and runs the [App] straight on the looper.
///
/// Native flavors call this with no overrides and get the native audio engine
/// (constructed behind [createNativeAudioEngine], so this file never names or
/// imports the engine package). The mock flavor injects both repositories
/// (sharing one mock engine) plus the [startConfig] to open straight into the
/// looper; injecting one repository requires the other.
Future<void> runLoopy(
  List<String> args, {
  LooperRepository? repository,
  SessionRepository? sessionRepository,
  EngineConfig? startConfig,
}) async {
  assert(
    (repository == null) == (sessionRepository == null),
    'inject both repositories together or neither',
  );
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
  // the session repository (which only reads/writes its loop PCM). On the
  // native path the engine is held by its [AudioEngine] interface — its
  // concrete type is never named here, keeping loopy_engine transitive.
  final LooperRepository looper;
  final SessionRepository session;
  if (repository == null || sessionRepository == null) {
    final engine = createNativeAudioEngine();
    looper = LooperRepository(engine: engine);
    session = SessionRepository(engine: engine);
  } else {
    looper = repository;
    session = sessionRepository;
  }

  // The native MIDI source feeds the controller pipeline; it is null when no
  // MIDI backend is available (e.g. the mock flavor), in which case the looper
  // runs with no controller source. The waveform sub-window already returned
  // above, so it never opens MIDI.
  final midiSource = createNativeMidiSource();
  // The GPIO source feeds the same controller pipeline from the Raspberry Pi
  // floor console's footswitches; it is null off-Pi (desktop, CI). On the Pi we
  // seed both MIDI and GPIO defaults so footswitches work on first boot with
  // zero config and a laptop MIDI pedal still works; off-Pi we fall back to the
  // repository's MIDI-only defaults.
  final gpioSource = createNativeGpioSource();
  final controllerRepository = ControllerRepository(
    sources: [?midiSource, ?gpioSource],
    mapping: gpioSource != null
        ? ControllerMapping.defaults().merge(ControllerMapping.gpioDefaults())
        : null,
  );
  // The bidirectional pedal reuses the MIDI source's single input capture and
  // opens its own MIDI output for LED feedback; null when no MIDI backend, in
  // which case the pedal cubit falls back to a no-op transport.
  final pedalRepository = createNativePedalRepository(midiSource);
  final settings = SettingsRepository(store: SharedPreferencesKeyValueStore());
  // Owns the MIDI input device lifecycle (enumerate / open / close, hotplug,
  // persistence). Borrows the shared [midiSource] (owned by the controller
  // pipeline) and never disposes it. Held independent of the engine so MIDI
  // changes never restart audio.
  final midiDeviceRepository = MidiDeviceRepository(
    source: midiSource,
    settings: settings,
  );

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
  if (startConfig != null) {
    looper.startEngine(startConfig);
  } else {
    final result = await tryAutoStartEngine(
      repository: looper,
      settings: settings,
    );
    asioDrivers = result.asioDrivers;
  }

  await bootstrap(
    () => App(
      repository: looper,
      controllerRepository: controllerRepository,
      midiDeviceRepository: midiDeviceRepository,
      pedalRepository: pedalRepository,
      settings: settings,
      waveformWindow: DesktopMultiWindowWaveformService(),
      sessionRepository: session,
      sessionDirectory: defaultSessionDirectory,
      initialAsioDrivers: asioDrivers,
    ),
  );
}
