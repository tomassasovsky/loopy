import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';
import '../../helpers/pump_app.dart';
import '../helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  group('PedalSettingsSection', () {
    late _MockLooperRepository looper;

    setUp(() {
      looper = _MockLooperRepository();
      when(
        () => looper.looperState,
      ).thenAnswer((_) => const Stream<LooperState>.empty());
    });

    PedalCubit cubitWith(FakePedalTransport transport) {
      final settings = SettingsRepository(store: FakeKeyValueStore());
      final store = ControlOverlay(looper: looper);
      addTearDown(store.dispose);
      final overlay = ControlOverlayCubit(overlay: store);
      addTearDown(overlay.close);
      return PedalCubit(
        pedal: PedalRepository(transport),
        looper: looper,
        overlay: store,
        intents: ControlIntents(
          looper: looper,
          overlay: store,
          settings: settings,
        ),
        settings: settings,
        pollInterval: Duration.zero, // no hotplug timer in widget tests
      );
    }

    Future<void> pumpSection(WidgetTester tester, PedalCubit cubit) =>
        tester.pumpApp(
          BlocProvider.value(
            value: cubit,
            child: const Scaffold(body: PedalSettingsSection()),
          ),
        );

    testWidgets('shows the empty state when no output ports exist', (
      tester,
    ) async {
      final cubit = cubitWith(FakePedalTransport());
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);

      expect(find.byKey(const Key('pedalSettings_empty')), findsOneWidget);
      expect(
        find.byKey(const Key('pedalSettings_device_picker')),
        findsNothing,
      );
    });

    testWidgets('shows the dropdown and status when outputs exist', (
      tester,
    ) async {
      final cubit = cubitWith(
        FakePedalTransport(
          outputs: const [MidiDevice(id: 'out', name: 'Loopy Pedal')],
        ),
      );
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);

      expect(
        find.byKey(const Key('pedalSettings_device_picker')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pedalSettings_status')), findsOneWidget);
    });

    testWidgets('the bind status is a live region (WCAG 4.1.3)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final cubit = cubitWith(
        FakePedalTransport(
          outputs: const [MidiDevice(id: 'out', name: 'Loopy Pedal')],
        ),
      );
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);

      expect(
        tester.getSemantics(find.byKey(const Key('pedalSettings_status'))),
        isSemantics(isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('empty output id does not collide with the None item', (
      tester,
    ) async {
      final cubit = cubitWith(
        FakePedalTransport(
          outputs: const [MidiDevice(id: '', name: 'IAC Driver')],
        ),
      );
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);

      expect(
        find.byKey(const Key('pedalSettings_device_picker')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('pedalSettings_device_picker')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('IAC Driver'));
      await tester.pumpAndSettle();

      expect(cubit.state.boundOutputId, '');
    });

    testWidgets('selecting a device binds it and shows the bound status', (
      tester,
    ) async {
      final cubit = cubitWith(
        FakePedalTransport(
          outputs: const [MidiDevice(id: 'out', name: 'Loopy Pedal')],
        ),
      );
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);
      await cubit.selectOutput(
        const PedalOutput(id: 'out', name: 'Loopy Pedal'),
      );
      await tester.pump();

      expect(cubit.state.bindStatus, PedalBindStatus.bound);
      expect(find.textContaining('Loopy Pedal'), findsWidgets);
    });
  });
}
