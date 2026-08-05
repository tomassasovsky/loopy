import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/pedal/pedal.dart';
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
      return PedalCubit(
        pedal: PedalRepository(transport),
        settings: settings,
        pollInterval: Duration.zero, // no hotplug timer in widget tests
      );
    }

    Future<void> pumpSection(
      WidgetTester tester,
      PedalCubit cubit, {
      bool consoleMode = false,
    }) => tester.pumpApp(
      BlocProvider.value(
        value: cubit,
        child: Scaffold(body: PedalSettingsSection(consoleMode: consoleMode)),
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
          outputs: const [MidiDevice(id: 'out', name: 'Segno Pedal')],
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
          outputs: const [MidiDevice(id: 'out', name: 'Segno Pedal')],
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
          outputs: const [MidiDevice(id: 'out', name: 'Segno Pedal')],
        ),
      );
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);
      await cubit.selectOutput(
        const PedalOutput(id: 'out', name: 'Segno Pedal'),
      );
      await tester.pump();

      expect(cubit.state.bindStatus, PedalBindStatus.bound);
      expect(find.textContaining('Segno Pedal'), findsWidgets);
    });

    testWidgets(
      'the firmware picker defaults to "not set" and offers every codec '
      'version (R6 manual gate)',
      (tester) async {
        final cubit = cubitWith(FakePedalTransport());
        addTearDown(cubit.close);

        await pumpSection(tester, cubit);

        expect(
          find.byKey(const Key('pedalSettings_firmware_picker')),
          findsOneWidget,
        );
        expect(cubit.state.firmwareVersion, isNull);
        // The closed dropdown shows the "not set" (unknown => v2) item.
        expect(find.textContaining('v2'), findsWidgets);

        await tester.tap(
          find.byKey(const Key('pedalSettings_firmware_picker')),
        );
        await tester.pumpAndSettle();
        for (
          var version = PedalCodec.protocolVersionV1;
          version <= PedalCodec.protocolVersionMax;
          version++
        ) {
          expect(find.text('Protocol v$version'), findsWidgets);
        }
      },
    );

    testWidgets('a saved firmware version renders as the selection', (
      tester,
    ) async {
      final cubit = cubitWith(FakePedalTransport());
      addTearDown(cubit.close);
      await cubit.selectFirmwareVersion(PedalCodec.protocolVersionV1);

      await pumpSection(tester, cubit);

      // The closed dropdown shows the persisted selection, not "not set".
      expect(
        find.text('Protocol v${PedalCodec.protocolVersionV1}'),
        findsOneWidget,
      );
    });

    testWidgets('selecting a firmware version updates the cubit', (
      tester,
    ) async {
      final cubit = cubitWith(FakePedalTransport());
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);
      await tester.tap(find.byKey(const Key('pedalSettings_firmware_picker')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('Protocol v${PedalCodec.protocolVersionV3}').last,
      );
      await tester.pumpAndSettle();

      expect(cubit.state.firmwareVersion, PedalCodec.protocolVersionV3);
    });

    group('the firmware-update banner (flow err-4)', () {
      const bannerKey = Key('pedalSettings_firmwareUpdate_banner');

      /// A cubit with [device] bound, so the banner's "a pedal is actually
      /// connected" precondition holds.
      Future<PedalCubit> boundCubit(String device) async {
        final cubit = cubitWith(
          FakePedalTransport(
            outputs: [MidiDevice(id: device, name: 'Segno Pedal')],
          ),
        );
        await cubit.selectOutput(PedalOutput(id: device, name: 'Segno Pedal'));
        return cubit;
      }

      testWidgets('is absent while no pedal is bound', (tester) async {
        final cubit = cubitWith(FakePedalTransport());
        addTearDown(cubit.close);

        await pumpSection(tester, cubit);

        expect(find.byKey(bannerKey), findsNothing);
      });

      testWidgets('appears for a bound pedal with no version set', (
        tester,
      ) async {
        final cubit = await boundCubit('out');
        addTearDown(cubit.close);

        await pumpSection(tester, cubit);

        // Unknown keeps the v2 floor, so FX mode is degraded on the wire —
        // the banner explains why rather than leaving it looking broken.
        expect(find.byKey(bannerKey), findsOneWidget);
        expect(find.text('Pedal firmware update available'), findsOneWidget);
      });

      testWidgets('appears for a bound pedal pinned below v3', (tester) async {
        final cubit = await boundCubit('out');
        addTearDown(cubit.close);
        await cubit.selectFirmwareVersion(PedalCodec.protocolVersionV1);

        await pumpSection(tester, cubit);

        expect(find.byKey(bannerKey), findsOneWidget);
      });

      testWidgets('never appears for the on-screen pedal', (tester) async {
        // It renders in this build — there is no firmware behind it to be
        // out of date, and it already encodes at the codec max.
        final cubit = await boundCubit(kSimulatorOutputId);
        addTearDown(cubit.close);

        await pumpSection(tester, cubit);

        expect(find.byKey(bannerKey), findsNothing);
      });

      testWidgets('disappears once the pedal is known to speak the newest '
          'protocol', (tester) async {
        final cubit = await boundCubit('out');
        addTearDown(cubit.close);
        await cubit.selectFirmwareVersion(PedalCodec.protocolVersionMax);

        await pumpSection(tester, cubit);

        expect(find.byKey(bannerKey), findsNothing);
      });
    });

    group('console build', () {
      // The console hides what CHOOSES hardware, never what CONFIGURES it.
      // Hiding both together is how the assignment surface became unreachable
      // on the one build that has no other route to it.
      testWidgets('keeps the assignment route reachable', (tester) async {
        final cubit = cubitWith(FakePedalTransport());
        addTearDown(cubit.close);

        await pumpSection(tester, cubit, consoleMode: true);

        expect(
          find.byKey(const Key('pedalSettings_openAssignments')),
          findsOneWidget,
        );
      });

      testWidgets('keeps the bind-status line', (tester) async {
        // With no picker, this is the only way to see whether auto-detect
        // actually found the pedal.
        final cubit = cubitWith(FakePedalTransport());
        addTearDown(cubit.close);

        await pumpSection(tester, cubit, consoleMode: true);

        expect(find.byType(PedalSettingsSection), findsOneWidget);
        expect(find.byKey(const Key('pedalSettings_empty')), findsNothing);
      });

      testWidgets('drops the device picker and the empty state', (
        tester,
      ) async {
        // Auto-detect binds the pedal by product name; a chooser would only
        // ever offer the one answer.
        final cubit = cubitWith(FakePedalTransport());
        addTearDown(cubit.close);

        await pumpSection(tester, cubit, consoleMode: true);

        expect(
          find.byKey(const Key('pedalSettings_device_picker')),
          findsNothing,
        );
        expect(find.byKey(const Key('pedalSettings_empty')), findsNothing);
      });

      testWidgets('desktop still shows the picker', (tester) async {
        final cubit = cubitWith(FakePedalTransport());
        addTearDown(cubit.close);

        await pumpSection(tester, cubit);

        expect(find.byKey(const Key('pedalSettings_empty')), findsOneWidget);
        expect(
          find.byKey(const Key('pedalSettings_openAssignments')),
          findsOneWidget,
        );
      });
    });
  });
}
