import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:midi_client/midi_client.dart';
import 'package:mocktail/mocktail.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _FakeMidiClient extends Mock implements MidiClient {}

/// MIDI status bytes (channel 0).
const int _cc = 0xB0;

void main() {
  // End-to-end: a native MIDI message pushed through the real
  // MidiControllerSource is parsed, mapped by ControllerRepository's default
  // mapping, and drives the LooperBloc — the full foot-pedal path with no
  // hardware. Uses MidiControllerSource.pushForTest over a mocked MidiClient so
  // no native library is touched.
  late LooperRepository repository;
  late StreamController<LooperState> stateController;
  late _FakeMidiClient client;
  late MidiControllerSource source;
  late ControllerRepository controller;

  setUp(() {
    repository = _MockLooperRepository();
    stateController = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => stateController.stream);
    when(
      () => repository.record(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.clear(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);

    client = _FakeMidiClient();
    when(client.close).thenReturn(0);
    source = MidiControllerSource(client: client);
    controller = ControllerRepository(sources: [source]);
  });

  tearDown(() async {
    await controller.dispose();
    await stateController.close();
  });

  test('a fake MIDI CC 80 press drives LooperBloc record', () async {
    final bloc = LooperBloc(repository: repository, controller: controller);
    addTearDown(bloc.close);

    // CC 80 (value 127) -> recordOverdub on channel 0 (default mapping).
    source.pushForTest(_cc, 80, 127);
    await pumpEventQueue();

    verify(() => repository.record()).called(1);
  });

  test('sub-debounce repeats of the same CC collapse to one record', () async {
    final bloc = LooperBloc(repository: repository, controller: controller);
    addTearDown(bloc.close);

    // Two presses within the 30 ms debounce window — only the first acts.
    source
      ..pushForTest(_cc, 80, 127)
      ..pushForTest(_cc, 80, 127, tsUs: 5000);
    await pumpEventQueue();

    verify(() => repository.record()).called(1);
  });

  test('an unmapped CC is ignored (no looper action)', () async {
    final bloc = LooperBloc(repository: repository, controller: controller);
    addTearDown(bloc.close);

    // CC 7 is not in the default mapping — it must fire no action.
    source.pushForTest(_cc, 7, 127);
    await pumpEventQueue();

    verifyNever(() => repository.record());
    verifyNever(() => repository.clear());
  });

  test(
    'the default tapTempo mapping (CC 84) drives repository.tapTempo',
    () async {
      when(repository.tapTempo).thenReturn(EngineResult.ok);
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      source.pushForTest(_cc, 84, 127);
      await pumpEventQueue();

      verify(repository.tapTempo).called(1);
      verifyNever(() => repository.record());
      verifyNever(() => repository.clear());
    },
  );
}
