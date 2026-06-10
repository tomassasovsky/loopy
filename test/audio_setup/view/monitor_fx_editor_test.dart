import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/audio_setup/view/monitor_fx_editor.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  group('MonitorFxEditor', () {
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
            child: const SingleChildScrollView(child: MonitorFxEditor()),
          ),
        ),
      ),
    );

    testWidgets('shows the empty hint when the bus is empty', (tester) async {
      await pump(tester);
      expect(
        find.byKey(const Key('audioSettings_monitorFx_empty')),
        findsOneWidget,
      );
    });

    testWidgets('Add appends an editable effect card', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('audioSettings_monitorFx_add')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('audioSettings_monitorFx_card_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audioSettings_monitorFx_type_0')),
        findsOneWidget,
      );
      // The default effect is a drive (two params).
      expect(cubit.state.effects.single.type, TrackEffectType.drive);
    });

    testWidgets('Remove drops the card back to the empty hint', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('audioSettings_monitorFx_add')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('audioSettings_monitorFx_remove_0')),
      );
      await tester.pumpAndSettle();

      expect(cubit.state.effects, isEmpty);
      expect(
        find.byKey(const Key('audioSettings_monitorFx_empty')),
        findsOneWidget,
      );
    });

    testWidgets('dragging a param slider forwards the value', (tester) async {
      await settings.saveMonitorEffects(
        encodeTrackEffects([TrackEffect(type: TrackEffectType.drive)]),
      );
      await cubit.load();
      await pump(tester);

      await tester.drag(
        find.byKey(const Key('audioSettings_monitorFx_param_0_0')),
        const Offset(200, 0),
      );
      await tester.pump();

      expect(cubit.state.effects.single.params[0], greaterThan(0));
    });
  });
}
