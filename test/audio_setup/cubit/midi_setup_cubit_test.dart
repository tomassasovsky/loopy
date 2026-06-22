import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockMidiDeviceRepository extends Mock implements MidiDeviceRepository {}

void main() {
  const dev1 = MidiDevice(id: 'id-1', name: 'FCB1010');
  const connecting = MidiConnection(status: MidiConnectionStatus.connecting);
  const connected = MidiConnection(
    devices: [dev1],
    selectedId: 'id-1',
    selectedName: 'FCB1010',
    status: MidiConnectionStatus.connected,
  );

  late _MockMidiDeviceRepository repository;
  late StreamController<MidiConnection> connections;
  late StreamController<void> activity;

  setUp(() {
    repository = _MockMidiDeviceRepository();
    connections = StreamController<MidiConnection>.broadcast();
    activity = StreamController<void>.broadcast();
    when(() => repository.connection).thenReturn(const MidiConnection());
    when(() => repository.connections).thenAnswer((_) => connections.stream);
    when(() => repository.activity).thenAnswer((_) => activity.stream);
    when(() => repository.select(any())).thenAnswer((_) async {});
    when(repository.selectNone).thenAnswer((_) async {});
  });

  tearDown(() async {
    await connections.close();
    await activity.close();
  });

  MidiSetupCubit build() => MidiSetupCubit(repository: repository);

  group('projection', () {
    test('seeds its initial state from the repository connection', () {
      when(() => repository.connection).thenReturn(connected);

      final cubit = build();
      addTearDown(cubit.close);

      expect(cubit.state.connection, connected);
      expect(cubit.state.activityTick, 0);
    });

    blocTest<MidiSetupCubit, MidiSetupState>(
      'mirrors the repository connection stream in order',
      build: build,
      act: (_) => connections
        ..add(connecting)
        ..add(connected),
      expect: () => const [
        MidiSetupState(connection: connecting),
        MidiSetupState(connection: connected),
      ],
    );

    blocTest<MidiSetupCubit, MidiSetupState>(
      'folds activity into a tick without touching the connection',
      build: build,
      act: (_) => activity
        ..add(null)
        ..add(null),
      expect: () => const [
        MidiSetupState(activityTick: 1),
        MidiSetupState(activityTick: 2),
      ],
    );
  });

  group('command forwarding', () {
    blocTest<MidiSetupCubit, MidiSetupState>(
      'select forwards to the repository',
      build: build,
      act: (cubit) => cubit.select('id-1'),
      verify: (_) => verify(() => repository.select('id-1')).called(1),
    );

    blocTest<MidiSetupCubit, MidiSetupState>(
      'selectNone forwards to the repository',
      build: build,
      act: (cubit) => cubit.selectNone(),
      verify: (_) => verify(repository.selectNone).called(1),
    );

    blocTest<MidiSetupCubit, MidiSetupState>(
      'refresh forwards to the repository',
      build: build,
      act: (cubit) => cubit.refresh(),
      verify: (_) => verify(repository.refresh).called(1),
    );
  });

  test('borrows the repository: never disposes it on close', () async {
    final cubit = build();

    await cubit.close();

    verifyNever(repository.dispose);
  });
}
