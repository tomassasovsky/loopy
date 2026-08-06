import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/high_contrast_cubit.dart';
import 'package:segno/looper/cubit/refresh_rate_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/system/system_tab.dart';
import 'package:segno/system/view/system_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';

class _MockUpdateRepository extends Mock implements UpdateRepository {}

class _MockLooperRepository extends Mock implements LooperRepository {}

final _v1 = Version.parse('0.1.0');
final _v2 = UpdateManifest(
  version: Version.parse('0.1.1'),
  bundle: 'segno-appliance-0.1.1.raucb',
  sha256: 's',
  channel: 'experimental',
);

void main() {
  setUpAll(() {
    registerFallbackValue(_v2);
    registerFallbackValue(Duration.zero);
  });

  late SettingsRepository settings;
  late UpdateRepository updates;
  late LooperRepository looper;
  late UpdateCubit update;
  late WaveformWindowCubit waveform;
  late HighContrastCubit contrast;
  late TracksCubit tracks;
  late RefreshRateCubit refresh;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    updates = _MockUpdateRepository();
    looper = _MockLooperRepository();
    when(() => updates.isSupported).thenReturn(true);
    when(() => updates.channel).thenReturn('experimental');
    when(() => updates.currentVersion()).thenAnswer((_) async => _v1);
    when(() => updates.stagedVersion()).thenAnswer((_) async => Version.none);
    when(() => updates.checkForUpdate()).thenAnswer((_) async => null);
    when(() => looper.setPollInterval(any())).thenReturn(null);
    update = UpdateCubit(updates: updates, settings: settings);
    waveform = WaveformWindowCubit(settings: settings);
    contrast = HighContrastCubit(settings: settings);
    tracks = TracksCubit(settings: settings);
    refresh = RefreshRateCubit(repository: looper, settings: settings);
  });

  tearDown(() async {
    await update.close();
    await waveform.close();
    await contrast.close();
    await tracks.close();
    await refresh.close();
  });

  Future<void> pump(WidgetTester tester, SystemTab tab) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiBlocProvider(
          providers: [
            BlocProvider<UpdateCubit>.value(value: update),
            BlocProvider<WaveformWindowCubit>.value(value: waveform),
            BlocProvider<HighContrastCubit>.value(value: contrast),
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<RefreshRateCubit>.value(value: refresh),
          ],
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(19),
              child: SystemTrayPanel(tab: tab, onTabChanged: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('Display tab', () {
    testWidgets('the three view switches drive their own settings', (
      tester,
    ) async {
      await pump(tester, SystemTab.display);

      await tester.tap(find.byKey(const Key('system_contrast_switch')));
      await tester.tap(find.byKey(const Key('system_indicators_switch')));
      await tester.pumpAndSettle();

      expect(contrast.state, isTrue);
      // Indicators start on outside console builds, so this is the flip.
      expect(tracks.state.showIndicators, isFalse);
    });

    testWidgets('the refresh rate picks through the chip dialog', (
      tester,
    ) async {
      await pump(tester, SystemTab.display);

      await tester.tap(find.byKey(const Key('system_refresh_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console_chip_30 Hz')));
      await tester.pumpAndSettle();

      expect(refresh.state, 30);
    });

    testWidgets('no failure banner until the window refuses', (tester) async {
      await pump(tester, SystemTab.display);

      expect(find.byKey(const Key('system_waveform_failed')), findsNothing);
    });
  });

  group('Updates tab', () {
    testWidgets('idle offers a check and says nothing is pending', (
      tester,
    ) async {
      await update.load();
      await pump(tester, SystemTab.updates);
      await tester.pump();

      expect(find.text('v0.1.0'), findsOneWidget);
      expect(find.text('experimental'), findsOneWidget);
      final banner = tester.widget<ConsoleBanner>(
        find.byKey(const Key('system_update_banner')),
      );
      // A restful state takes the green dot, not the amber one.
      expect(banner.settled, isTrue);
      expect(banner.failed, isFalse);
    });

    testWidgets('an offer downloads only when asked', (tester) async {
      when(() => updates.checkForUpdate()).thenAnswer((_) async => _v2);
      when(
        () => updates.downloadAndStage(any()),
      ).thenAnswer((_) => Stream<double>.fromIterable(const [0.5, 1]));
      await update.load();
      await update.check();
      await pump(tester, SystemTab.updates);
      await tester.pump();

      expect(find.text('v0.1.1 is available.'), findsOneWidget);
      verifyNever(
        () => updates.downloadAndStage(any()),
      );

      await tester.tap(find.byKey(const Key('system_update_action')));
      await tester.pumpAndSettle();

      verify(
        () => updates.downloadAndStage(any()),
      ).called(1);
    });

    testWidgets('a failed check says so, in red, and offers a retry', (
      tester,
    ) async {
      when(() => updates.checkForUpdate()).thenThrow(Exception('no server'));
      await update.load();
      await update.check();
      await pump(tester, SystemTab.updates);
      await tester.pump();

      final banner = tester.widget<ConsoleBanner>(
        find.byKey(const Key('system_update_banner')),
      );
      expect(banner.failed, isTrue);
      expect(banner.actionLabel, 'Try again');
    });

    testWidgets('an unsupported platform says so and offers nothing', (
      tester,
    ) async {
      when(() => updates.isSupported).thenReturn(false);
      await update.load();
      await pump(tester, SystemTab.updates);
      await tester.pump();

      final banner = tester.widget<ConsoleBanner>(
        find.byKey(const Key('system_update_banner')),
      );
      expect(banner.actionLabel, isNull);
    });
  });
}
