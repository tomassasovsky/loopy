import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/audio_setup/view/monitor_fx_editor.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  group('InputMonitorTile', () {
    late SettingsRepository settings;
    late LooperRepository repository;
    late MonitorCubit cubit;

    setUp(() {
      settings = SettingsRepository(store: FakeKeyValueStore());
      repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      cubit = MonitorCubit(repository: repository, settings: settings);
    });

    tearDown(() => repository.dispose());

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<MonitorCubit>.value(
            value: cubit,
            child: const SingleChildScrollView(
              child: InputMonitorTile(input: 0, outputChannels: 2),
            ),
          ),
        ),
      ),
    );

    testWidgets('hides the effect controls until the monitor is enabled', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.byKey(const Key('audioSettings_monitorFx_add_0')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const Key('audioSettings_monitorInput_switch_0')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('audioSettings_monitorFx_empty_0')),
        findsOneWidget,
      );
    });

    testWidgets('Add appends an editable effect card', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);

      await tester.tap(find.byKey(const Key('audioSettings_monitorFx_add_0')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('audioSettings_monitorFx_card_0_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audioSettings_monitorFx_type_0_0')),
        findsOneWidget,
      );
      // The default effect is a drive (two params).
      expect(
        cubit.state.forInput(0).effects.single.type,
        TrackEffectType.drive,
      );
    });

    testWidgets('Remove drops the card back to the empty hint', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);
      await tester.tap(find.byKey(const Key('audioSettings_monitorFx_add_0')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('audioSettings_monitorFx_remove_0_0')),
      );
      await tester.pumpAndSettle();

      expect(cubit.state.forInput(0).effects, isEmpty);
      expect(
        find.byKey(const Key('audioSettings_monitorFx_empty_0')),
        findsOneWidget,
      );
    });

    testWidgets('dragging a param slider forwards the value', (tester) async {
      await settings.saveMonitorInput(0, enabled: true, outputMask: 0x3);
      await settings.saveMonitorInputEffects(
        0,
        encodeTrackEffects([TrackEffect(type: TrackEffectType.drive)]),
      );
      await cubit.load();
      await pump(tester);

      await tester.drag(
        find.byKey(const Key('audioSettings_monitorFx_param_0_0_0')),
        const Offset(200, 0),
      );
      await tester.pump();

      expect(cubit.state.forInput(0).effects.single.params[0], greaterThan(0));
    });

    testWidgets('the dry-send chips set the monitor dry output mask', (
      tester,
    ) async {
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);

      // The dry send starts off (mask 0); tap output 2's dry chip -> 0x2.
      final chip = find.byKey(const Key('audioSettings_monitorDry_0_1'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(cubit.state.forInput(0).dryOutputMask, 0x2);
    });
  });
}
