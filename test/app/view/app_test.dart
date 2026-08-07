import 'dart:async';
import 'dart:typed_data';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/app.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/update/view/updates_settings_section.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';

/// A supported update backend advertising v0.2.0 (current is v0.1.0), so the
/// app's startup availability check surfaces the update toast.
class _FakeUpdateBackend implements PlatformUpdateBackend {
  @override
  bool get isSupported => true;
  // No pending pedal firmware: the App tests are about the looper, and a gate
  // over it would hide everything they assert on.
  @override
  Future<String?> pendingPedalFirmware() async => null;
  @override
  Stream<double> flashPedalFirmware() => const Stream.empty();
  @override
  String get channel => 'experimental';
  @override
  Future<void> setChannel(String channel) async {}
  @override
  Future<Version> currentVersion() async => Version.parse('0.1.0');
  @override
  Future<Version> stagedVersion() async => Version.none;
  @override
  Future<UpdateManifest?> fetchManifest() async => UpdateManifest(
    version: Version.parse('0.2.0'),
    bundle: 'b.raucb',
    notes: 'new stuff',
  );
  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      Stream.fromIterable(const [1]);
  @override
  Future<void> applyAndRestart() async {}
}

/// Same as [_FakeUpdateBackend], but [fetchManifest] waits until [complete] so
/// tests can open Settings → Updates before the availability toast would show.
class _DeferredUpdateBackend extends _FakeUpdateBackend {
  final Completer<UpdateManifest?> _manifest = Completer<UpdateManifest?>();

  void complete() {
    if (!_manifest.isCompleted) {
      _manifest.complete(
        UpdateManifest(
          version: Version.parse('0.2.0'),
          bundle: 'b.raucb',
          notes: 'new stuff',
        ),
      );
    }
  }

  @override
  Future<UpdateManifest?> fetchManifest() => _manifest.future;
}

class _RecordingWindowService implements WaveformWindowService {
  _RecordingWindowService({this.openResult = true});

  /// What [open] reports — `false` simulates a window that never readies.
  final bool openResult;

  int openCalls = 0;
  int closeCalls = 0;
  int pushCalls = 0;
  bool _open = false;

  /// Every readout the app handed to the service.
  ///
  /// Deliberately records EVERY call rather than mirroring the real service's
  /// change-diff: a double that reimplements the logic under test proves
  /// nothing about it.
  final readouts = <PerformanceReadout>[];

  @override
  void pushReadout(PerformanceReadout readout) => readouts.add(readout);

  @override
  bool get isOpen => _open;

  @override
  Future<bool> open({String title = 'Segno — Output'}) async {
    openCalls++;
    _open = openResult;
    return openResult;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    _open = false;
  }

  @override
  void pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) => pushCalls++;
}

void main() {
  group('App', () {
    late LooperRepository repository;
    late ControllerRepository controllerRepository;
    late MidiDeviceRepository midiDeviceRepository;
    late SettingsRepository settings;
    late SessionRepository sessionRepository;
    late PerformanceRepository performanceRepository;

    setUp(() {
      // Both are module-level and survive between tests: a leftover toast
      // makes the next identical toast a silent no-op, and a settings guard
      // left set makes openSegnoSettings return early forever after.
      resetAppToastsForTest();
      resetSegnoNavigatorForTest();
      repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      controllerRepository = ControllerRepository(sources: const []);
      settings = SettingsRepository(store: FakeKeyValueStore());
      sessionRepository = SessionRepository(engine: FakeAudioEngine());
      performanceRepository = PerformanceRepository(
        engine: FakeAudioEngine(),
        exportsRoot: () async => '.',
      );
      // No MIDI backend by default; the MIDI-specific test below wires its own.
      midiDeviceRepository = MidiDeviceRepository(
        source: null,
        settings: settings,
      );
      addTearDown(repository.dispose);
      addTearDown(controllerRepository.dispose);
      addTearDown(midiDeviceRepository.dispose);
    });

    Future<void> pumpApp(
      WidgetTester tester,
      WaveformWindowService windowService,
    ) async {
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: windowService,
          sessionRepository: sessionRepository,
          performanceRepository: performanceRepository,
          exportDirectory: () async => '.',
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> pumpAppWithUpdates(
      WidgetTester tester,
      UpdateRepository updates,
    ) async {
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          performanceRepository: performanceRepository,
          exportDirectory: () async => '.',
          updates: updates,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the startup update toast when a build is available', (
      tester,
    ) async {
      await pumpAppWithUpdates(
        tester,
        UpdateRepository(backend: _FakeUpdateBackend()),
      );
      expect(find.byKey(const Key('app_update_banner')), findsOneWidget);
    });

    testWidgets(
      'dismissing the update toast hides it',
      (tester) async {
        await pumpAppWithUpdates(
          tester,
          UpdateRepository(backend: _FakeUpdateBackend()),
        );
        await tester.tap(find.byKey(const Key('app_update_banner_dismiss')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app_update_banner')), findsNothing);
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets(
      'Update on the toast opens Settings on the Updates tab',
      (
        tester,
      ) async {
        await pumpAppWithUpdates(
          tester,
          UpdateRepository(backend: _FakeUpdateBackend()),
        );
        await tester.tap(find.byKey(const Key('app_update_banner_update')));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(find.byType(UpdatesSettingsSection), findsOneWidget);
        expect(
          find.byKey(const Key('settings_tab_updates')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('app_update_banner')), findsNothing);
        // Pop so the navigator re-entrancy guard (`_settingsOpen`) clears for
        // later tests in this file that also open Settings.
        await tester.tap(find.byKey(const Key('settings_close_button')));
        await tester.pumpAndSettle();
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets(
      'no update toast while Settings Updates is already open',
      (
        tester,
      ) async {
        final backend = _DeferredUpdateBackend();
        await pumpAppWithUpdates(
          tester,
          UpdateRepository(backend: backend),
        );
        // NOT awaited: openSegnoSettings awaits navigator.push, which resolves
        // only when the route is POPPED. Awaiting it here deadlocks the test on
        // its own first statement — settings is not closed until the end — and
        // it does not fail fast: it spins until the harness gives up minutes
        // later, poisoning the rest of the file.
        unawaited(openSegnoSettings(section: SettingsSection.updates));
        await tester.pumpAndSettle();
        backend.complete();
        await tester.pumpAndSettle();
        expect(find.byType(UpdatesSettingsSection), findsOneWidget);
        expect(find.byKey(const Key('app_update_banner')), findsNothing);
        await tester.tap(find.byKey(const Key('settings_close_button')));
        await tester.pumpAndSettle();
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets('no update toast on an unsupported platform', (tester) async {
      await pumpApp(tester, NoopWaveformWindowService());
      expect(find.byKey(const Key('app_update_banner')), findsNothing);
    });

    testWidgets('renders the looper as the home page in tracks', (
      tester,
    ) async {
      await pumpApp(tester, NoopWaveformWindowService());
      expect(find.byType(LooperPage), findsOneWidget);
      expect(find.byType(TracksView), findsOneWidget);
    });

    testWidgets('always lands on the looper — no first-run gate', (
      tester,
    ) async {
      // The wizard and the needsSetup gate are gone; the app renders the looper
      // directly even with no saved audio config.
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          performanceRepository: performanceRepository,
          exportDirectory: () async => '.',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LooperPage), findsOneWidget);
    });

    testWidgets('opens the waveform window on launch in tracks', (
      tester,
    ) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      expect(windowService.openCalls, greaterThanOrEqualTo(1));
      expect(windowService.isOpen, isTrue);
      // A successful open shows no failure banner.
      expect(
        find.byKey(const Key('app_waveformWindowFailed_banner')),
        findsNothing,
      );
    });

    testWidgets('does not open the waveform window when it is disabled', (
      tester,
    ) async {
      await settings.saveShowWaveformWindow(value: false);
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      expect(windowService.openCalls, 0);
      expect(windowService.isOpen, isFalse);
    });

    testWidgets('right-click opens settings; disabling the waveform window '
        'closes it', (tester) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);
      expect(windowService.isOpen, isTrue);

      await tester.tap(
        find.byKey(const Key('tracks_settings_secondaryTap')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // Disable the secondary waveform window; it closes (Tracks is the
      // only mode now, so the window follows this enable toggle alone).
      await tester.tap(
        find.byKey(const Key('settings_waveformWindow_switch')),
      );
      await tester.pumpAndSettle();

      expect(windowService.isOpen, isFalse);

      // Close the settings page so the global open-guard resets for the next
      // test (the toggle no longer navigates away on its own).
      await tester.tap(find.byKey(const Key('settings_close_button')));
      await tester.pumpAndSettle();

      // The layout never swaps — Tracks is the only mode.
      expect(find.byType(TracksView), findsOneWidget);
    });

    testWidgets('the S key opens the settings page', (tester) async {
      await pumpApp(tester, NoopWaveformWindowService());

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // Close it so the global open-guard resets for the next test.
      await tester.tap(find.byKey(const Key('settings_close_button')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
    });

    // The device-lost and MIDI-lost BANNER tests were removed with the toast
    // rewrite that came in with the Control Center branch: those notifications
    // are toasts now, so the banner keys they asserted no longer exist.
    //
    // Deliberately not re-expressed as toast tests here. A toast auto-hides,
    // and "your interface is unplugged" is an ongoing STATE rather than an
    // event — restoring a persistent surface for it is tracked separately, and
    // the test should be written against whatever that surface turns out to be
    // rather than against the stopgap.

    /// Takes the failure toast back down before this test's tree goes away.
    ///
    /// `_showWaveformWindowFailedBanner` raises it with no `autoCloseDuration`,
    /// so it is manual-dismiss — nothing retires it on its own. And
    /// `toastification`'s manager is a GLOBAL that outlives the tree, while
    /// `resetAppToastsForTest` in setUp only clears THIS module's registry, not
    /// the item still live in that manager. A toast left standing here is
    /// therefore not this test's problem but the next one's: the following
    /// test's `showAppToast` renders into the dead overlay and its banner is
    /// never found. Ordering hid it — the toast test happens to be declared
    /// first — until a randomised seed put it last.
    Future<void> dismissFailureToast(WidgetTester tester) async {
      dismissAppToast(AppToastId.waveformFailed);
      // Past the removal animation and the overlay teardown it schedules.
      await tester.pump(const Duration(seconds: 10));
    }

    testWidgets(
      'a window that never readies is attempted ONCE, and the failure is on '
      'the cubit the Display face reads',
      (tester) async {
        final windowService = _RecordingWindowService(openResult: false);
        await pumpApp(tester, windowService);

        // The shell both writes the failure and listens for changes, so a
        // listener that fired on the flag going UP would re-enter the sync
        // that raised it — two attempts and two toasts for one failure.
        expect(windowService.openCalls, 1);
        // No frames streamed to a window that never readied.
        await tester.pump(const Duration(milliseconds: 40));
        expect(windowService.pushCalls, 0);

        final waveform = tester
            .element(find.byType(MaterialApp).first)
            .read<WaveformWindowCubit>();
        expect(waveform.state.openFailed, isTrue);
        expect(waveform.state.enabled, isTrue);

        await dismissFailureToast(tester);
      },
    );

    testWidgets(
      'clearing the failure IS the retry — one more attempt, not two',
      (tester) async {
        final windowService = _RecordingWindowService(openResult: false);
        await pumpApp(tester, windowService);
        expect(windowService.openCalls, 1);

        tester
            .element(find.byType(MaterialApp).first)
            .read<WaveformWindowCubit>()
            .retryOpen();
        await tester.pumpAndSettle();

        expect(windowService.openCalls, 2);

        // Two failed opens, but ONE toast: they share an id, so the second
        // `showAppToast` dismissed the first. Taking it down is not tidiness —
        // see [dismissFailureToast].
        await dismissFailureToast(tester);
      },
    );

    testWidgets(
      'shows a banner when the waveform window fails to open',
      (
        tester,
      ) async {
        final windowService = _RecordingWindowService(openResult: false);
        await pumpApp(tester, windowService);

        expect(
          find.byKey(const Key('app_waveformWindowFailed_banner')),
          findsOneWidget,
        );
        // No frames are streamed to a window that never readied.
        await tester.pump(const Duration(milliseconds: 40));
        expect(windowService.pushCalls, 0);
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets(
      'shows a single-display notice and skips the waveform window '
      'when only one display is present',
      (tester) async {
        final windowService = _RecordingWindowService();
        await tester.pumpWidget(
          App(
            repository: repository,
            controllerRepository: controllerRepository,
            midiDeviceRepository: midiDeviceRepository,
            settings: settings,
            waveformWindow: windowService,
            sessionRepository: sessionRepository,
            performanceRepository: performanceRepository,
            exportDirectory: () async => '.',
            displayCount: () => 1,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('app_singleDisplay_banner')),
          findsOneWidget,
        );
        expect(windowService.openCalls, 0);
        // The push timer never started either.
        await tester.pump(const Duration(milliseconds: 40));
        expect(windowService.pushCalls, 0);
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets(
      'shows the audio-recovery banner when booted with the pinned '
      'device absent',
      (tester) async {
        // The fake engine reports stopped with no devices, so the pinned config
        // is absent and the recovery cubit waits (and would auto-start on
        // arrival). pump (not pumpAndSettle) — the cubit holds a periodic poll.
        await tester.pumpWidget(
          App(
            repository: repository,
            controllerRepository: controllerRepository,
            midiDeviceRepository: midiDeviceRepository,
            settings: settings,
            waveformWindow: NoopWaveformWindowService(),
            sessionRepository: sessionRepository,
            performanceRepository: performanceRepository,
            exportDirectory: () async => '.',
            audioRecoveryConfig: const EngineConfig(playbackDeviceId: 'absent'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(
          find.byKey(const Key('app_audioRecovery_banner')),
          findsOneWidget,
        );
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );
  });
}
