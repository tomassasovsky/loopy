import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late SettingsRepository settings;
  late UiModeCubit uiMode;
  late BigPictureCubit bigPicture;
  late WaveformWindowCubit waveformWindow;
  late BankCubit bank;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    uiMode = UiModeCubit(settings: settings);
    bigPicture = BigPictureCubit(settings: settings);
    waveformWindow = WaveformWindowCubit(settings: settings);
    bank = BankCubit(settings: settings);
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(
            value: _MockLooperRepository(),
          ),
          RepositoryProvider<SettingsRepository>.value(value: settings),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<UiModeCubit>.value(value: uiMode),
            BlocProvider<BigPictureCubit>.value(value: bigPicture),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<BankCubit>.value(value: bank),
          ],
          child: const BigPictureSettingsPage(),
        ),
      ),
    ),
  );

  testWidgets('toggling the waveform window persists the preference', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(
      find.byKey(const Key('bpSettings_waveformWindow_switch')),
    );
    await tester.pumpAndSettle();

    expect(waveformWindow.state, isFalse);
    expect(await settings.loadShowWaveformWindow(), isFalse);
  });

  testWidgets('toggling the second bank persists it', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('bpSettings_bank_switch')));
    await tester.pumpAndSettle();

    expect(bank.state.enabled, isTrue);
    expect(await settings.loadBankEnabled(), isTrue);
  });

  testWidgets('renaming a track updates the list and persists it', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('TRACK 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('bpSettings_trackName_0')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('bpSettings_rename_field')),
      'DRUMS',
    );
    await tester.tap(find.byKey(const Key('bpSettings_rename_save')));
    await tester.pumpAndSettle();

    expect(find.text('DRUMS'), findsOneWidget);
    expect(await settings.loadTrackName(0), 'DRUMS');
  });

  testWidgets('the Big Picture switch reflects the current mode', (
    tester,
  ) async {
    await pump(tester);

    final switchTile = tester.widget<SwitchListTile>(
      find.byKey(const Key('bpSettings_bigPicture_switch')),
    );
    expect(switchTile.value, isTrue); // default is big picture
  });
}
