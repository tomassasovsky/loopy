import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:midi_client/midi_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockMidiSource extends Mock implements MidiControllerSource {}

void main() {
  const dev1 = MidiDevice(id: 'id-1', name: 'FCB1010');
  const dev2 = MidiDevice(id: 'id-2', name: 'SoftStep');

  late _MockMidiSource source;
  late FakeKeyValueStore store;
  late SettingsRepository settings;
  late StreamController<RawControllerInput> activity;
  late List<MidiDevice> enumerated;

  setUp(() {
    source = _MockMidiSource();
    store = FakeKeyValueStore();
    settings = SettingsRepository(store: store);
    activity = StreamController<RawControllerInput>.broadcast();
    enumerated = const [];
    when(() => source.enumerate()).thenAnswer((_) => enumerated);
    when(() => source.activity).thenAnswer((_) => activity.stream);
    when(() => source.open(any())).thenReturn(0);
    when(source.close).thenReturn(0);
  });

  tearDown(() => activity.close());

  // Builds a cubit with the hotplug timer disabled (tests drive [refresh]).
  MidiSetupCubit build() => MidiSetupCubit(
    source: source,
    settings: settings,
    pollInterval: Duration.zero,
  );

  // Builds the cubit and lets the async launch hydrate complete.
  Future<MidiSetupCubit> hydrated() async {
    final cubit = build();
    await pumpEventQueue();
    return cubit;
  }

  group('enumeration + initial state', () {
    test('starts with no selection and the enumerated devices', () async {
      enumerated = const [dev1, dev2];
      final cubit = await hydrated();
      addTearDown(cubit.close);

      expect(cubit.state.status, MidiSetupStatus.none);
      expect(cubit.state.devices, const [dev1, dev2]);
      expect(cubit.state.selectedId, '');
    });

    test('a null source degrades gracefully (no devices, no crash)', () async {
      final cubit = MidiSetupCubit(
        source: null,
        settings: settings,
        pollInterval: Duration.zero,
      );
      addTearDown(cubit.close);
      await pumpEventQueue();

      expect(cubit.state.status, MidiSetupStatus.none);
      expect(cubit.state.devices, isEmpty);
      await cubit.select('id-1'); // no-op, must not throw
      expect(cubit.state.selectedId, '');
    });

    test('a raw activity message bumps the activity tick', () async {
      final cubit = await hydrated();
      addTearDown(cubit.close);
      final before = cubit.state.activityTick;

      activity.add(
        const RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 80,
          value: 127,
        ),
      );
      await pumpEventQueue();

      expect(cubit.state.activityTick, before + 1);
    });
  });

  group('select', () {
    test('opens the device, persists it, and connects', () async {
      enumerated = const [dev1, dev2];
      final cubit = await hydrated();
      addTearDown(cubit.close);

      await cubit.select('id-1');

      expect(cubit.state.status, MidiSetupStatus.connected);
      expect(cubit.state.selectedId, 'id-1');
      expect(cubit.state.selectedName, 'FCB1010');
      verify(() => source.open('id-1')).called(1);
      final saved = await settings.loadMidiDevice();
      expect(saved?.id, 'id-1');
      expect(saved?.name, 'FCB1010');
    });

    test(
      'switching A→B opens B and persists B (native open closes A)',
      () async {
        enumerated = const [dev1, dev2];
        final cubit = await hydrated();
        addTearDown(cubit.close);

        await cubit.select('id-1');
        await cubit.select('id-2');

        expect(cubit.state.selectedId, 'id-2');
        expect(cubit.state.status, MidiSetupStatus.connected);
        verify(() => source.open('id-2')).called(1);
        expect((await settings.loadMidiDevice())?.id, 'id-2');
      },
    );

    test(
      'a failed open surfaces a recoverable error, retaining the pin',
      () async {
        enumerated = const [dev1];
        when(() => source.open('id-1')).thenReturn(5);
        final cubit = await hydrated();
        addTearDown(cubit.close);

        await cubit.select('id-1');

        expect(cubit.state.status, MidiSetupStatus.error);
        expect(cubit.state.errorDetail, '5');
        expect(cubit.state.selectedId, 'id-1');
        // The selection is still persisted so a later retry / replug recovers.
        expect((await settings.loadMidiDevice())?.id, 'id-1');
      },
    );
  });

  group('None', () {
    test('closes the device, clears the keys, and stops events', () async {
      enumerated = const [dev1];
      final cubit = await hydrated();
      addTearDown(cubit.close);
      await cubit.select('id-1');

      await cubit.selectNone();

      expect(cubit.state.status, MidiSetupStatus.none);
      expect(cubit.state.selectedId, '');
      verify(source.close).called(1);
      expect(await settings.loadMidiDevice(), isNull);
    });
  });

  group('launch auto-reconnect', () {
    test('re-opens a saved device that is present', () async {
      await settings.saveMidiDevice(id: 'id-1', name: 'FCB1010');
      enumerated = const [dev1];

      final cubit = await hydrated();
      addTearDown(cubit.close);

      expect(cubit.state.status, MidiSetupStatus.connected);
      expect(cubit.state.selectedId, 'id-1');
      verify(() => source.open('id-1')).called(1);
    });

    test('retains a saved device that is absent as deviceGone', () async {
      await settings.saveMidiDevice(id: 'id-9', name: 'Ghost');
      enumerated = const [dev1]; // id-9 not present

      final cubit = await hydrated();
      addTearDown(cubit.close);

      expect(cubit.state.status, MidiSetupStatus.deviceGone);
      expect(cubit.state.selectedId, 'id-9');
      expect(cubit.state.selectedName, 'Ghost');
      verifyNever(() => source.open(any()));
    });
  });

  group('hotplug', () {
    test('losing the connected device marks it gone and raises lost', () async {
      enumerated = const [dev1];
      final cubit = await hydrated();
      addTearDown(cubit.close);
      await cubit.select('id-1');

      enumerated = const []; // unplugged
      cubit.refresh();

      expect(cubit.state.status, MidiSetupStatus.deviceGone);
      expect(cubit.state.connectivity, MidiConnectivity.lost);
      expect(cubit.state.connectivityDeviceName, 'FCB1010');
    });

    test('replugging reconnects the device and raises restored', () async {
      enumerated = const [dev1];
      final cubit = await hydrated();
      addTearDown(cubit.close);
      await cubit.select('id-1');
      clearInteractions(source);

      enumerated = const [];
      cubit.refresh(); // lost
      enumerated = const [dev1];
      cubit.refresh(); // restored

      expect(cubit.state.status, MidiSetupStatus.connected);
      expect(cubit.state.connectivity, MidiConnectivity.restored);
      verify(() => source.open('id-1')).called(1);
    });

    test('does not flag a transition on the first observation', () async {
      enumerated = const [dev1];
      final cubit = await hydrated();
      addTearDown(cubit.close);
      await cubit.select('id-1');

      cubit.refresh(); // still present, no transition

      expect(cubit.state.connectivity, MidiConnectivity.none);
      expect(cubit.state.status, MidiSetupStatus.connected);
    });
  });

  group('audio independence', () {
    test('selecting / switching / clearing touches only the MIDI source and '
        'settings — never an audio engine', () async {
      enumerated = const [dev1, dev2];
      final cubit = await hydrated();
      addTearDown(cubit.close);

      await cubit.select('id-1');
      await cubit.select('id-2');
      await cubit.selectNone();

      // The cubit has no LooperRepository collaborator at all; its only
      // interactions are open/close/enumerate (and reading the activity stream
      // once at construction) on the MIDI source.
      verify(() => source.open(any())).called(2);
      verify(source.close).called(1);
      verify(() => source.enumerate()).called(greaterThanOrEqualTo(1));
      verify(() => source.activity).called(greaterThanOrEqualTo(1));
      verifyNoMoreInteractions(source);
    });
  });
}
