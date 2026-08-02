import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';
import '../helpers/fake_pedal_transport.dart';

/// The pedal LINK tests: output binding, hotplug reconciliation, and the
/// picker state. The pedal's BEHAVIOR (footswitch decode, LED frames) is
/// `ControlCubit`'s and is covered by test/control/control_cubit_test.dart.
void main() {
  group('PedalCubit', () {
    late FakePedalTransport transport;
    late PedalRepository pedal;
    late SettingsRepository settings;

    setUp(() {
      transport = FakePedalTransport(
        outputs: const [MidiDevice(id: 'out', name: 'Pedal')],
      );
      pedal = PedalRepository(transport);
      settings = SettingsRepository(store: FakeKeyValueStore());
    });

    PedalCubit buildCubit() => PedalCubit(
      pedal: pedal,
      settings: settings,
      pollInterval: Duration.zero, // tests drive reconnect() directly
    );

    test('reconnect re-binds the saved output across replugs', () async {
      await settings.savePedalOutputDevice(id: 'pedal', name: 'Pedal');
      transport.outputs = const []; // saved device absent at launch
      final cubit = buildCubit();
      await cubit.load();
      expect(cubit.state.boundOutputId, isNull);

      // Appears -> reconnect binds it.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.state.boundOutputId, 'pedal');

      // Vanishes -> reconnect drops the stale handle.
      transport.outputs = const [];
      cubit.reconnect();
      expect(cubit.state.boundOutputId, isNull);

      // Reappears -> reconnect re-binds without a relaunch.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.state.boundOutputId, 'pedal');
      await cubit.close();
    });

    test('reconnect leaves an unpinned (None) output alone', () async {
      final cubit = buildCubit();
      await cubit.load(); // nothing saved -> no pinned device
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.state.boundOutputId, isNull);
      await cubit.close();
    });

    test('reconnect reflects the output set into state', () async {
      transport.outputs = const [];
      final cubit = buildCubit();
      await cubit.load();
      expect(cubit.state.availableOutputs, isEmpty);

      // Set changes -> the picker reads the new outputs off state.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      // The repository maps the transport MidiDevice to a domain PedalOutput.
      expect(cubit.state.availableOutputs, const [
        PedalOutput(id: 'pedal', name: 'Pedal'),
      ]);

      // Vanishes -> state reflects the empty set again.
      transport.outputs = const [];
      cubit.reconnect();
      expect(cubit.state.availableOutputs, isEmpty);
      await cubit.close();
    });

    test(
      'selectOutput binds + persists; selectNone unbinds + clears',
      () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        await pumpEventQueue();
        expect(cubit.state.bindStatus, PedalBindStatus.bound);
        expect(cubit.state.boundOutputId, 'out');
        expect((await settings.loadPedalOutputDevice())?.id, 'out');

        await cubit.selectNone();
        await pumpEventQueue();
        expect(cubit.state.boundOutputId, isNull);
        expect(await settings.loadPedalOutputDevice(), isNull);
        await cubit.close();
      },
    );

    test('close sends a goodbye frame to the bound pedal', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
      transport.sent.clear();

      await cubit.close();

      final frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame?.isGoodbye, isTrue);
    });

    group('console auto-detect', () {
      const pedalOut = MidiDevice(id: 'out-p', name: 'VAMP Loopstation MIDI 1');
      const otherOut = MidiDevice(id: 'out-x', name: 'Launchpad Mini');
      const productNames = ['VAMP Loopstation'];

      PedalCubit buildAuto() => PedalCubit(
        pedal: pedal,
        settings: settings,
        pollInterval: Duration.zero,
        autoBindProductNames: productNames,
      );

      test('binds the matching output with nothing persisted', () async {
        transport.outputs = const [otherOut, pedalOut];
        final cubit = buildAuto();
        await cubit.load();

        expect(cubit.state.boundOutputId, 'out-p');
        await cubit.close();
      });

      test('binds nothing when no output matches', () async {
        transport.outputs = const [otherOut];
        final cubit = buildAuto();
        await cubit.load();

        expect(cubit.state.boundOutputId, isNull);
        await cubit.close();
      });

      test('never binds when auto-detect is off (desktop)', () async {
        transport.outputs = const [pedalOut];
        final cubit = buildCubit();
        await cubit.load();

        expect(cubit.state.boundOutputId, isNull);
        await cubit.close();
      });

      test('binds the pedal when it appears after launch', () async {
        transport.outputs = const [otherOut];
        final cubit = buildAuto();
        await cubit.load();
        expect(cubit.state.boundOutputId, isNull);

        transport.outputs = const [otherOut, pedalOut];
        cubit.reconnect();

        expect(cubit.state.boundOutputId, 'out-p');
        await cubit.close();
      });

      test(
        'a persisted device outranks auto-detect, even when absent',
        () async {
          await settings.savePedalOutputDevice(id: 'ghost', name: 'Ghost');
          transport.outputs = const [pedalOut];
          final cubit = buildAuto();
          await cubit.load();

          expect(cubit.state.boundOutputId, isNull);
          await cubit.close();
        },
      );

      test('a user pick outranks auto-detect and survives a vanish', () async {
        transport.outputs = const [otherOut, pedalOut];
        final cubit = buildAuto();
        await cubit.load();

        await cubit.selectOutput(
          const PedalOutput(id: 'out-x', name: 'Launchpad Mini'),
        );
        transport.outputs = const [pedalOut]; // the picked device unplugs
        cubit.reconnect();

        // The pin stays on the user's device rather than jumping to the pedal.
        expect(cubit.state.boundOutputId, isNull);
        expect((await settings.loadPedalOutputDevice())?.id, 'out-x');
        await cubit.close();
      });

      test(
        're-resolves an auto-bound pin whose id changed on replug',
        () async {
          transport.outputs = const [pedalOut];
          final cubit = buildAuto();
          await cubit.load();
          expect(cubit.state.boundOutputId, 'out-p');

          // ALSA renumbers clients across a replug; a console has no picker to
          // recover with, so the pin has to follow the name, not the id.
          transport.outputs = const [
            MidiDevice(id: 'out-p-renumbered', name: 'VAMP Loopstation MIDI 1'),
          ];
          cubit.reconnect();

          expect(cubit.state.boundOutputId, 'out-p-renumbered');
          await cubit.close();
        },
      );

      test('selecting None is not undone by the next poll', () async {
        transport.outputs = const [pedalOut];
        final cubit = buildAuto();
        await cubit.load();
        expect(cubit.state.boundOutputId, 'out-p');

        await cubit.selectNone();
        cubit.reconnect();

        expect(cubit.state.boundOutputId, isNull);
        await cubit.close();
      });

      test('an auto-bound pin is not persisted', () async {
        transport.outputs = const [pedalOut];
        final cubit = buildAuto();
        await cubit.load();
        expect(cubit.state.boundOutputId, 'out-p');

        // Re-deriving every launch is what keeps a renumbered id from sticking.
        expect(await settings.loadPedalOutputDevice(), isNull);
        await cubit.close();
      });
    });

    group('flashed firmware version (part B)', () {
      PedalCubit buildWithFlashed(Future<int?> Function() reader) => PedalCubit(
        pedal: pedal,
        settings: settings,
        pollInterval: Duration.zero,
        flashedProtocolVersion: reader,
      );

      test('a flashed record outranks the manual setting', () async {
        // The flasher wrote that pedal, so it knows what runs on it; the
        // manual setting is a guess a firmware update silently invalidates.
        await settings.savePedalFirmwareVersion(PedalCodec.protocolVersionV2);
        final cubit = buildWithFlashed(
          () async => PedalCodec.protocolVersionV3,
        );

        await cubit.load();

        expect(cubit.state.firmwareVersion, PedalCodec.protocolVersionV3);
        expect(pedal.firmwareProtocolVersion, PedalCodec.protocolVersionV3);
        await cubit.close();
      });

      test('falls back to the manual setting with no record', () async {
        await settings.savePedalFirmwareVersion(PedalCodec.protocolVersionV3);
        final cubit = buildWithFlashed(() async => null);

        await cubit.load();

        expect(cubit.state.firmwareVersion, PedalCodec.protocolVersionV3);
        await cubit.close();
      });

      test('no record and no setting keeps the unknown => v2 floor', () async {
        final cubit = buildWithFlashed(() async => null);

        await cubit.load();

        expect(cubit.state.firmwareVersion, isNull);
        expect(pedal.targetProtocolVersion, PedalCodec.protocolVersionV2);
        await cubit.close();
      });

      test('desktop (no reader) is unaffected', () async {
        await settings.savePedalFirmwareVersion(PedalCodec.protocolVersionV3);
        final cubit = buildCubit();

        await cubit.load();

        expect(cubit.state.firmwareVersion, PedalCodec.protocolVersionV3);
        await cubit.close();
      });
    });

    group('firmware version (R6 pre-#331 gate)', () {
      test(
        'load applies the persisted version to the repository before frames '
        'flow, and reflects it in state',
        () async {
          await settings.savePedalFirmwareVersion(
            PedalCodec.protocolVersionV3,
          );
          final cubit = buildCubit();
          await cubit.load();
          expect(cubit.state.firmwareVersion, PedalCodec.protocolVersionV3);
          expect(
            pedal.targetProtocolVersion,
            PedalCodec.protocolVersionV3,
          );
          await cubit.close();
        },
      );

      test(
        'load with nothing persisted keeps the unknown => v2 floor',
        () async {
          final cubit = buildCubit();
          await cubit.load();
          expect(cubit.state.firmwareVersion, isNull);
          expect(pedal.targetProtocolVersion, PedalCodec.protocolVersionV2);
          await cubit.close();
        },
      );

      test(
        'selectFirmwareVersion persists, applies, and drives what pushState '
        'encodes',
        () async {
          final cubit = buildCubit();
          await cubit.selectFirmwareVersion(PedalCodec.protocolVersionV3);

          expect(cubit.state.firmwareVersion, PedalCodec.protocolVersionV3);
          expect(
            await settings.loadPedalFirmwareVersion(),
            PedalCodec.protocolVersionV3,
          );

          // The knob is live: a frame pushed now goes out at v3.
          await cubit.selectOutput(const PedalOutput(id: 'out', name: 'P'));
          transport.sent.clear();
          pedal.pushState(PedalStateFrame.blank());
          expect(transport.sent.last[2], PedalCodec.protocolVersionV3);
          await cubit.close();
        },
      );

      test(
        'swapping in a DIFFERENT pedal drops the version back to unknown',
        () async {
          final cubit = buildCubit();
          await cubit.selectOutput(const PedalOutput(id: 'out', name: 'P'));
          await cubit.selectFirmwareVersion(PedalCodec.protocolVersionV2);

          // A version learned for one pedal says nothing about the next one:
          // carried over it would encode a v3 pedal's frames at v2 and tell
          // the user to flash firmware it already runs.
          await cubit.selectOutput(const PedalOutput(id: 'out2', name: 'P2'));

          expect(cubit.state.firmwareVersion, isNull);
          expect(await settings.loadPedalFirmwareVersion(), isNull);
          expect(pedal.targetProtocolVersion, PedalCodec.protocolVersionV2);
          await cubit.close();
        },
      );

      test(
        're-selecting the SAME pedal keeps the version the user set',
        () async {
          final cubit = buildCubit();
          await cubit.selectOutput(const PedalOutput(id: 'out', name: 'P'));
          await cubit.selectFirmwareVersion(PedalCodec.protocolVersionV3);

          await cubit.selectOutput(const PedalOutput(id: 'out', name: 'P'));

          expect(cubit.state.firmwareVersion, PedalCodec.protocolVersionV3);
          await cubit.close();
        },
      );

      test(
        'selectFirmwareVersion(null) clears back to unknown => v2',
        () async {
          final cubit = buildCubit();
          await cubit.selectFirmwareVersion(PedalCodec.protocolVersionV3);
          await cubit.selectFirmwareVersion(null);

          expect(cubit.state.firmwareVersion, isNull);
          expect(await settings.loadPedalFirmwareVersion(), isNull);
          expect(pedal.targetProtocolVersion, PedalCodec.protocolVersionV2);
          await cubit.close();
        },
      );
    });
  });
}
