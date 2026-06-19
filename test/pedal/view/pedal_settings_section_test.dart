import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
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

    PedalCubit cubitWith(FakePedalTransport transport) => PedalCubit(
      pedal: PedalRepository(transport),
      looper: looper,
      settings: SettingsRepository(store: FakeKeyValueStore()),
      pollInterval: Duration.zero, // no hotplug timer in widget tests
    );

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
