import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

class _MockMidiSource extends Mock implements MidiControllerSource {}

class _InMemoryStore implements KeyValueStore {
  final Map<String, Object> values = {};

  @override
  Future<int?> getInt(String key) async => values[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> setString(String key, String value) async => values[key] = value;

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<void> setBool(String key, {required bool value}) async =>
      values[key] = value;

  @override
  Future<double?> getDouble(String key) async => values[key] as double?;

  @override
  Future<void> setDouble(String key, double value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<void> clear() async => values.clear();
}

void main() {
  const dev1 = MidiDevice(id: 'id-1', name: 'FCB1010');
  const dev2 = MidiDevice(id: 'id-2', name: 'SoftStep');

  late _MockMidiSource source;
  late _InMemoryStore store;
  late SettingsRepository settings;
  late StreamController<RawControllerInput> activity;
  late List<MidiDevice> enumerated;

  setUp(() {
    source = _MockMidiSource();
    store = _InMemoryStore();
    settings = SettingsRepository(store: store);
    activity = StreamController<RawControllerInput>.broadcast();
    enumerated = const [];
    when(() => source.enumerate()).thenAnswer((_) => enumerated);
    when(() => source.activity).thenAnswer((_) => activity.stream);
    when(() => source.open(any())).thenReturn(0);
    when(source.close).thenReturn(0);
  });

  tearDown(() => activity.close());

  // Builds a repository with the hotplug timer disabled (tests drive
  // [refresh]).
  MidiDeviceRepository build() => MidiDeviceRepository(
    source: source,
    settings: settings,
    pollInterval: Duration.zero,
  );

  // Builds the repository and lets the async launch hydrate complete.
  Future<MidiDeviceRepository> hydrated() async {
    final repository = build();
    await pumpEventQueue();
    return repository;
  }

  group('enumeration + initial state', () {
    test('starts with no selection and the enumerated devices', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.status, MidiConnectionStatus.none);
      expect(repository.connection.devices, const [dev1, dev2]);
      expect(repository.connection.selectedId, '');
    });

    test('a null source degrades gracefully (no devices, no crash)', () async {
      final repository = MidiDeviceRepository(
        source: null,
        settings: settings,
        pollInterval: Duration.zero,
      );
      addTearDown(repository.dispose);
      await pumpEventQueue();

      expect(repository.connection.status, MidiConnectionStatus.none);
      expect(repository.connection.devices, isEmpty);
      expect(repository.activity, emitsDone); // empty stream
      await repository.select('id-1'); // no-op, must not throw
      expect(repository.connection.selectedId, '');
    });

    test('republishes raw source activity for the indicator', () async {
      final repository = await hydrated();
      addTearDown(repository.dispose);
      final ticks = <void>[];
      final sub = repository.activity.listen(ticks.add);
      addTearDown(sub.cancel);

      activity.add(
        const RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 80,
          value: 127,
        ),
      );
      await pumpEventQueue();

      expect(ticks, hasLength(1));
    });
  });

  group('select', () {
    test('opens the device, persists it, and connects', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      await repository.select('id-1');

      expect(repository.connection.status, MidiConnectionStatus.connected);
      expect(repository.connection.selectedId, 'id-1');
      expect(repository.connection.selectedName, 'FCB1010');
      verify(() => source.open('id-1')).called(1);
      final saved = await settings.loadMidiDevice();
      expect(saved?.id, 'id-1');
      expect(saved?.name, 'FCB1010');
    });

    test(
      'switching A→B opens B and persists B (native open closes A)',
      () async {
        enumerated = const [dev1, dev2];
        final repository = await hydrated();
        addTearDown(repository.dispose);

        await repository.select('id-1');
        await repository.select('id-2');

        expect(repository.connection.selectedId, 'id-2');
        expect(repository.connection.status, MidiConnectionStatus.connected);
        verify(() => source.open('id-2')).called(1);
        expect((await settings.loadMidiDevice())?.id, 'id-2');
      },
    );

    test(
      'a failed open surfaces a recoverable error, retaining the pin',
      () async {
        enumerated = const [dev1];
        when(() => source.open('id-1')).thenReturn(5);
        final repository = await hydrated();
        addTearDown(repository.dispose);

        await repository.select('id-1');

        expect(repository.connection.status, MidiConnectionStatus.error);
        expect(repository.connection.errorDetail, '5');
        expect(repository.connection.selectedId, 'id-1');
        // The selection is still persisted so a later retry / replug recovers.
        expect((await settings.loadMidiDevice())?.id, 'id-1');
      },
    );

    test('re-selecting the already-connected device is a no-op', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      clearInteractions(source);

      await repository.select('id-1'); // already connected → no reopen

      verifyNever(() => source.open(any()));
      expect(repository.connection.status, MidiConnectionStatus.connected);
    });
  });

  group('None', () {
    test('closes the device, clears the keys, and stops events', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');

      await repository.selectNone();

      expect(repository.connection.status, MidiConnectionStatus.none);
      expect(repository.connection.selectedId, '');
      verify(source.close).called(1);
      expect(await settings.loadMidiDevice(), isNull);
    });
  });

  group('launch auto-reconnect', () {
    test('re-opens a saved device that is present', () async {
      await settings.saveMidiDevice(id: 'id-1', name: 'FCB1010');
      enumerated = const [dev1];

      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.status, MidiConnectionStatus.connected);
      expect(repository.connection.selectedId, 'id-1');
      verify(() => source.open('id-1')).called(1);
    });

    test('retains a saved device that is absent as deviceGone', () async {
      await settings.saveMidiDevice(id: 'id-9', name: 'Ghost');
      enumerated = const [dev1]; // id-9 not present

      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.status, MidiConnectionStatus.deviceGone);
      expect(repository.connection.selectedId, 'id-9');
      expect(repository.connection.selectedName, 'Ghost');
      verifyNever(() => source.open(any()));
    });
  });

  group('hotplug', () {
    test('losing the connected device marks it gone and raises lost', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');

      enumerated = const []; // unplugged
      repository.refresh();

      expect(repository.connection.status, MidiConnectionStatus.deviceGone);
      expect(repository.connection.connectivity, MidiConnectivity.lost);
      expect(repository.connection.connectivityDeviceName, 'FCB1010');
    });

    test('replugging reconnects the device and raises restored', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      clearInteractions(source);

      enumerated = const [];
      repository.refresh(); // lost
      enumerated = const [dev1];
      repository.refresh(); // restored

      expect(repository.connection.status, MidiConnectionStatus.connected);
      expect(repository.connection.connectivity, MidiConnectivity.restored);
      verify(() => source.open('id-1')).called(1);
    });

    test('does not flag a transition on the first observation', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');

      repository.refresh(); // still present, no transition

      expect(repository.connection.connectivity, MidiConnectivity.none);
      expect(repository.connection.status, MidiConnectionStatus.connected);
    });

    test(
      'a failed reopen on replug surfaces the error after restored',
      () async {
        enumerated = const [dev1];
        final repository = await hydrated();
        addTearDown(repository.dispose);
        await repository.select('id-1');

        enumerated = const [];
        repository.refresh(); // lost
        when(() => source.open('id-1')).thenReturn(7);
        enumerated = const [dev1];
        repository.refresh(); // present again, but the reopen fails

        expect(repository.connection.status, MidiConnectionStatus.error);
        expect(repository.connection.errorDetail, '7');
        expect(repository.connection.connectivity, MidiConnectivity.restored);
      },
    );

    test('the poll timer drives periodic refresh', () {
      enumerated = const [dev1];
      fakeAsync((async) {
        final repository = MidiDeviceRepository(
          source: source,
          settings: settings,
          pollInterval: const Duration(milliseconds: 500),
        );
        async.flushMicrotasks(); // launch hydrate
        clearInteractions(source);

        async.elapse(const Duration(milliseconds: 500)); // one poll tick

        verify(() => source.enumerate()).called(greaterThanOrEqualTo(1));
        // The poll reconciled the live enumeration into the connection.
        expect(repository.connection.devices, const [dev1]);
        unawaited(repository.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('connections stream', () {
    test('replays the current connection to a late subscriber', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      // Subscribe after the launch enumerate/hydrate already ran.
      final first = await repository.connections.first;

      expect(first.devices, const [dev1, dev2]);
      expect(first.status, MidiConnectionStatus.none);
    });

    test('emits as the lifecycle advances', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      final statuses = <MidiConnectionStatus>[];
      final sub = repository.connections.listen((c) => statuses.add(c.status));
      addTearDown(sub.cancel);

      await repository.select('id-1');
      await pumpEventQueue();

      expect(
        statuses,
        containsAllInOrder([
          MidiConnectionStatus.connecting,
          MidiConnectionStatus.connected,
        ]),
      );
      expect(statuses.last, MidiConnectionStatus.connected);
    });
  });

  group('audio independence', () {
    test('selecting / switching / clearing touches only the MIDI source and '
        'settings — never an audio engine', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      await repository.select('id-1');
      await repository.select('id-2');
      await repository.selectNone();

      // The repository has no LooperRepository collaborator at all; its only
      // interactions are open/close/enumerate on the MIDI source.
      verify(() => source.open(any())).called(2);
      verify(source.close).called(1);
      verify(() => source.enumerate()).called(greaterThanOrEqualTo(1));
      verifyNoMoreInteractions(source);
    });
  });

  group('disposal', () {
    test('does not dispose the borrowed source', () async {
      final repository = await hydrated();

      await repository.dispose();

      // The source is owned by the ControllerRepository; the repository only
      // borrows it and must never tear it down.
      verifyNever(() => source.dispose());
    });
  });

  group('MidiConnection', () {
    test('isSelectedPresent reflects the current enumeration', () {
      const absent = MidiConnection(devices: [dev1], selectedId: 'id-9');
      const present = MidiConnection(devices: [dev1], selectedId: 'id-1');

      expect(absent.isSelectedPresent, isFalse);
      expect(present.isSelectedPresent, isTrue);
    });

    test('copyWith replaces fields; clearError resets the detail', () {
      const base = MidiConnection(
        status: MidiConnectionStatus.error,
        errorDetail: '5',
      );

      final updated = base.copyWith(status: MidiConnectionStatus.connecting);
      expect(updated.status, MidiConnectionStatus.connecting);
      expect(updated.errorDetail, '5'); // retained without clearError

      expect(base.copyWith(clearError: true).errorDetail, isNull);
    });

    test('value equality is by props', () {
      expect(
        const MidiConnection(selectedId: 'a'),
        const MidiConnection(selectedId: 'a'),
      );
      expect(
        const MidiConnection(selectedId: 'a'),
        isNot(const MidiConnection(selectedId: 'b')),
      );
    });
  });
}
