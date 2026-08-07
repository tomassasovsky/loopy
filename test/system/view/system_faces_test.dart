import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/high_contrast_cubit.dart';
import 'package:segno/looper/cubit/refresh_rate_cubit.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/system/system_tab.dart';
import 'package:segno/system/view/system_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockUpdateCubit extends MockCubit<UpdateState> implements UpdateCubit {}

/// A client that throws every read, for the "cannot read the disk" face.
class _FailingFactsClient implements ConsoleFactsClient {
  @override
  bool get isSupported => true;

  @override
  Future<StorageUsage> storage() async => throw StateError('no disk');

  @override
  Future<ConsoleFacts> facts() async => throw StateError('no disk');

  @override
  Future<int> deleteCapturesOlderThan(int days) async => 0;

  @override
  Future<String> exportDestination() async => '';

  @override
  Future<void> exportEverything(String destination) async {}
}

const _devices = <AudioDevice>[
  AudioDevice(
    id: 'scarlett-out',
    name: 'Scarlett 18i20',
    isDefault: true,
    isInput: false,
    outputChannels: 20,
  ),
];

const _open = EngineStatus(
  isConnected: true,
  deviceName: 'Scarlett 18i20',
  sampleRate: 48000,
  bufferFrames: 128,
  outputChannels: 20,
  devicePresent: true,
);

/// What the app knows about itself once `UpdateCubit.load` has run: a version
/// and a channel. The default for these previews, because a build that knows
/// neither is a build whose About face drops the row entirely.
final _running = UpdateState(
  supported: true,
  channel: 'experimental',
  currentVersion: Version.parse('0.1.0'),
);

void main() {
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late SettingsTrayCubit tray;
  late WaveformWindowCubit waveform;
  late HighContrastCubit contrast;
  late TracksCubit tracks;
  late RefreshRateCubit refresh;
  late AudioSetupCubit audio;
  late PedalCubit pedal;
  late ConsoleFactsCubit facts;
  late _MockUpdateCubit update;

  setUpAll(() {
    registerFallbackValue(const EngineConfig());
    registerFallbackValue(Duration.zero);
  });

  setUp(() {
    repository = _MockLooperRepository();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(const LooperState(status: _open));
    when(() => repository.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        playbackDeviceId: 'scarlett-out',
      ),
    );
    when(() => repository.startEngine(any())).thenReturn(EngineResult.ok);
    when(repository.stopEngine).thenReturn(EngineResult.ok);
    when(repository.measureLatency).thenReturn(EngineResult.ok);
    when(repository.detectLoopback).thenReturn(const LoopbackInfo.none());
    when(repository.devices).thenReturn(_devices);
    when(repository.asioDrivers).thenReturn(const []);
    when(() => repository.setPollInterval(any())).thenReturn(null);
  });

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(SystemTrayPanel)));

  /// Mounts the System face with the providers the real tray inherits.
  ///
  /// 1920x1080, deliberately: these faces are drawn for that surface, and the
  /// default 800x600 view pushes the lower rows below the fold where a tap
  /// lands on nothing.
  Future<void> pump(
    WidgetTester tester, {
    SystemTab tab = SystemTab.display,
    ConsoleFactsClient? client,
    UpdateState? updateState,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    settings = SettingsRepository(store: FakeKeyValueStore());
    tray = SettingsTrayCubit(settings: settings)
      ..showSystemTab(tab)
      ..showDestination(SettingsTrayDestination.system);
    waveform = WaveformWindowCubit(settings: settings);
    contrast = HighContrastCubit(settings: settings);
    tracks = TracksCubit(settings: settings);
    refresh = RefreshRateCubit(repository: repository, settings: settings);
    audio = AudioSetupCubit(
      repository: repository,
      settings: settings,
      deviceRefreshInterval: Duration.zero,
    );
    pedal = PedalCubit(
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: settings,
      pollInterval: Duration.zero,
    );
    facts = ConsoleFactsCubit(
      // Zero latency: even `Future.delayed(Duration.zero)` schedules a timer,
      // and a testWidgets body that awaits one without pumping waits forever.
      client: client ?? FakeConsoleFactsClient(latency: Duration.zero),
      settings: settings,
    );
    update = _MockUpdateCubit();
    when(update.startDownload).thenAnswer((_) async {});
    when(update.check).thenAnswer((_) async {});
    when(update.applyAndRestart).thenAnswer((_) async {});
    when(
      () => update.setAutoCheck(value: any(named: 'value')),
    ).thenAnswer((_) async {});
    when(
      () => update.setExperimentalChannel(value: any(named: 'value')),
    ).thenAnswer((_) async {});
    whenListen(
      update,
      const Stream<UpdateState>.empty(),
      initialState: updateState ?? _running,
    );

    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(tray.close()));
    addTearDown(() => unawaited(waveform.close()));
    addTearDown(() => unawaited(contrast.close()));
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(refresh.close()));
    addTearDown(() => unawaited(audio.close()));
    addTearDown(() => unawaited(pedal.close()));
    addTearDown(() => unawaited(facts.close()));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: tray),
              BlocProvider.value(value: waveform),
              BlocProvider.value(value: contrast),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: refresh),
              BlocProvider.value(value: audio),
              BlocProvider.value(value: pedal),
              BlocProvider.value(value: facts),
              BlocProvider<UpdateCubit>.value(value: update),
            ],
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(19),
                child: SystemTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('SYSTEM / display', () {
    testWidgets('the three view settings are switches, never on/off words', (
      tester,
    ) async {
      await pump(tester);

      for (final key in const [
        Key('system_waveform_switch'),
        Key('system_high_contrast_switch'),
        Key('system_track_indicators_switch'),
      ]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key');
      }
      // Never the WORDS: a boolean on this console is a switch (#498).
      expect(find.text('On'), findsNothing);
      expect(find.text('Off'), findsNothing);
    });

    testWidgets('the refresh rate opens in place onto a grid of tokens', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      // Shut: the chooser holds nothing tappable.
      expect(find.byKey(const Key('system_refresh_rate_30')), findsNothing);

      await tester.tap(find.byKey(const Key('system_refresh_rate_row')));
      await tester.pumpAndSettle();

      // A grid, not a list of rows — every option is a bare token.
      expect(find.byType(ConsoleChipGrid<int>), findsOneWidget);
      for (final hz in RefreshRateCubit.options) {
        expect(find.byKey(Key('system_refresh_rate_$hz')), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('system_refresh_rate_30')));
      await tester.pumpAndSettle();

      expect(refresh.state, 30);
      expect(find.text(l10n.refreshRateHz(30)), findsWidgets);
      // A pick-one: answering it shuts the drawer.
      expect(find.byKey(const Key('system_refresh_rate_120')), findsNothing);
    });

    testWidgets('the chooser is mid-animation one frame after the tap — a '
        'golden only ever photographs the settled state', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('system_refresh_rate_row')));
      await tester.pump();
      await tester.pump(kConsoleMotion ~/ 2);

      // The CHOOSER's box, not the grid's: the grid is laid out at its full
      // height from the first frame and the drawer clips it, so measuring the
      // grid would report a settled size all the way through the animation.
      const chooser = Key('system_refresh_rate_chooser');
      final opening = tester.getRect(find.byKey(chooser));
      await tester.pumpAndSettle();
      final settled = tester.getRect(find.byKey(chooser));

      // Grown from nothing rather than swapped in at full height.
      expect(opening.height, lessThan(settled.height));
      expect(opening.height, greaterThan(0));
    });

    testWidgets('a window that did not open says so where the setting is, '
        'in the words the toast uses, and offers a retry', (tester) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      expect(
        find.byKey(const Key('system_waveform_failed_banner')),
        findsNothing,
      );

      waveform.reportOpenFailed();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('system_waveform_failed_banner')),
        findsOneWidget,
      );
      expect(find.text(l10n.waveformWindowFailedBanner), findsOneWidget);

      await tester.tap(find.byKey(const Key('system_waveform_retry')));
      await tester.pumpAndSettle();

      // Clearing the flag IS the retry — the shell re-syncs on any change.
      expect(waveform.state.openFailed, isFalse);
      expect(waveform.state.enabled, isTrue);
      expect(
        find.byKey(const Key('system_waveform_failed_banner')),
        findsNothing,
      );
    });
  });

  group('SYSTEM / updates', () {
    testWidgets('an offer sits untouched until the button is pressed', (
      tester,
    ) async {
      await pump(
        tester,
        tab: SystemTab.updates,
        updateState: _running.copyWith(
          phase: UpdatePhase.available,
          available: UpdateManifest(
            version: Version.parse('0.1.1'),
            bundle: 'b',
            channel: 'experimental',
          ),
        ),
      );
      final l10n = l10nOf(tester);

      verifyNever(update.startDownload);
      expect(find.text(l10n.updatesAvailableBanner('0.1.1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('system_update_action')));
      await tester.pumpAndSettle();

      verify(update.startDownload).called(1);
    });

    testWidgets('downloading draws a real progress bar, not a spinner', (
      tester,
    ) async {
      await pump(
        tester,
        tab: SystemTab.updates,
        updateState: _running.copyWith(
          phase: UpdatePhase.downloading,
          progress: 0.42,
          available: UpdateManifest(
            version: Version.parse('0.1.1'),
            bundle: 'b',
            channel: 'experimental',
          ),
        ),
      );

      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(ConsoleBanner.progressKey),
      );
      expect(bar.value, closeTo(0.42, 0.001));
      // Nothing to press while it runs.
      expect(find.byKey(const Key('system_update_action')), findsNothing);
    });

    testWidgets('a failed check is red and offers a retry', (tester) async {
      await pump(
        tester,
        tab: SystemTab.updates,
        updateState: _running.copyWith(
          phase: UpdatePhase.error,
          errorMessage: 'connection refused',
        ),
      );
      final l10n = l10nOf(tester);

      final banner = tester.widget<ConsoleBanner>(
        find.byKey(const Key('system_update_banner')),
      );
      expect(banner.tone, ConsoleBannerTone.failure);
      expect(
        find.text(l10n.updatesCheckFailedBanner('connection refused')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('system_update_action')));
      await tester.pumpAndSettle();
      verify(update.check).called(1);
    });

    testWidgets('idle and up-to-date are restful, and never a dead end', (
      tester,
    ) async {
      await pump(tester, tab: SystemTab.updates);
      final l10n = l10nOf(tester);

      var banner = tester.widget<ConsoleBanner>(
        find.byKey(const Key('system_update_banner')),
      );
      expect(banner.tone, ConsoleBannerTone.steady);
      expect(find.text(l10n.updatesCheckNowTitle), findsOneWidget);

      whenListen(
        update,
        Stream.value(_running.copyWith(phase: UpdatePhase.upToDate)),
        initialState: _running,
      );
      await tester.pumpAndSettle();

      banner = tester.widget<ConsoleBanner>(
        find.byKey(const Key('system_update_banner')),
      );
      expect(banner.tone, ConsoleBannerTone.steady);
      expect(find.byKey(const Key('system_update_action')), findsOneWidget);
    });

    testWidgets('an unsupported platform offers nothing at all', (
      tester,
    ) async {
      await pump(
        tester,
        tab: SystemTab.updates,
        updateState: const UpdateState(),
      );
      final l10n = l10nOf(tester);

      expect(find.text(l10n.updatesUnsupportedBanner), findsOneWidget);
      expect(find.byKey(const Key('system_update_action')), findsNothing);
    });
  });

  group('SYSTEM / storage', () {
    testWidgets('deleting captures asks first, and the figures afterwards '
        'come from a re-read', (tester) async {
      await pump(tester, tab: SystemTab.storage);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.storageGigabytes('6.2')), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('system_storage_delete_captures')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('console_confirm_confirm')), findsOneWidget);

      // Backing out changes nothing.
      await tester.tap(find.byKey(const Key('console_confirm_cancel')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.storageGigabytes('6.2')), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('system_storage_delete_captures')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();

      // The fake mutates its own figures, so this number could not have been
      // guessed by subtracting anything the face already held.
      expect(find.text(l10n.storageGigabytes('6.2')), findsNothing);
      expect(find.text(l10n.storageGigabytes('2.1')), findsOneWidget);
    });

    testWidgets('nowhere to export is a fact, not a failure — the row says '
        'so and is not tappable', (tester) async {
      await pump(
        tester,
        tab: SystemTab.storage,
        client: FakeConsoleFactsClient(
          latency: Duration.zero,
          exportVolumeMounted: false,
        ),
      );
      final l10n = l10nOf(tester);

      expect(find.text(l10n.storageNoUsb), findsOneWidget);
      final row = tester.widget<ConsoleRow>(
        find.byKey(const Key('system_storage_export')),
      );
      expect(row.onTap, isNull);
    });

    testWidgets('a build that cannot read the disk says so and draws no '
        'rows — zeroes as facts would be worse', (tester) async {
      await pump(
        tester,
        tab: SystemTab.storage,
        client: _FailingFactsClient(),
      );
      final l10n = l10nOf(tester);

      expect(find.text(l10n.storageUnknown), findsOneWidget);
      expect(find.byKey(const Key('system_storage_card')), findsNothing);
      expect(find.text(l10n.storageGigabytes('0.0')), findsNothing);
    });
  });

  group('SYSTEM / about', () {
    testWidgets('a console names itself, its serial and its image', (
      tester,
    ) async {
      await pump(tester, tab: SystemTab.about);

      expect(find.text('VAMP 16'), findsOneWidget);
      expect(find.text('VMP-16-0042'), findsOneWidget);
      expect(find.text('Yocto scarthgap · kernel 6.12-rt'), findsOneWidget);
      expect(find.text('16″ 1920×1080 · touch'), findsOneWidget);
    });

    testWidgets('a build that is not a console omits the identity rows, and '
        'keeps the ones it does know', (tester) async {
      await pump(
        tester,
        tab: SystemTab.about,
        client: const UnsupportedConsoleFactsClient(),
      );

      // Left out, not drawn with a dash.
      expect(find.byKey(const Key('system_about_name')), findsNothing);
      expect(find.byKey(const Key('system_about_serial')), findsNothing);
      expect(find.byKey(const Key('system_about_image')), findsNothing);
      expect(find.byKey(const Key('system_about_panel')), findsNothing);
      expect(find.text('—'), findsNothing);

      // Still says what it does know.
      expect(find.byKey(const Key('system_about_app')), findsOneWidget);
      expect(find.byKey(const Key('system_about_licence')), findsOneWidget);
    });

    testWidgets(
      "with no console facts, the app row IS the card's last and takes the "
      'closing edge',
      (tester) async {
        await pump(
          tester,
          tab: SystemTab.about,
          client: const UnsupportedConsoleFactsClient(),
        );

        final app = tester.widget<ConsoleRow>(
          find.byKey(const Key('system_about_app')),
        );
        expect(app.showDivider, isFalse);
      },
    );

    testWidgets('with them, the image row takes that job and the app row '
        'hands its hairline back', (tester) async {
      await pump(tester, tab: SystemTab.about);

      final app = tester.widget<ConsoleRow>(
        find.byKey(const Key('system_about_app')),
      );
      expect(app.showDivider, isTrue);
      final image = tester.widget<ConsoleRow>(
        find.byKey(const Key('system_about_image')),
      );
      expect(image.showDivider, isFalse);
    });

    testWidgets('renaming the console keys off the serial', (tester) async {
      await pump(tester, tab: SystemTab.about);

      await facts.rename('Stage left');
      await tester.pumpAndSettle();

      expect(find.text('Stage left'), findsOneWidget);
      expect(await settings.loadConsoleName('VMP-16-0042'), 'Stage left');
      // Not under a bare key, and not under another rig's serial.
      expect(await settings.loadConsoleName('VMP-16-0043'), isNull);
    });
  });

  group('the strip', () {
    testWidgets('every tab opens onto a face', (tester) async {
      for (final tab in SystemTab.values) {
        await pump(tester, tab: tab);
        expect(
          find.byKey(Key('system_${tab.name}_tab')),
          findsOneWidget,
          reason: '${tab.name} opened onto nothing',
        );
      }
    });
  });
}
