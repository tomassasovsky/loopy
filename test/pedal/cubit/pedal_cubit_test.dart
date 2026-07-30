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
