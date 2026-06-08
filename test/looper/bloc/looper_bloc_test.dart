import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _FakeControllerSource implements ControllerSource {
  final StreamController<RawControllerInput> _controller =
      StreamController<RawControllerInput>.broadcast();
  @override
  Stream<RawControllerInput> get inputs => _controller.stream;
  void press(ControllerSourceKind kind, int id) =>
      _controller.add(RawControllerInput(kind: kind, id: id, value: 127));
  @override
  Future<void> dispose() => _controller.close();
}

const _playingState = LooperState(
  transport: TransportState(isRunning: true, masterLengthFrames: 48000),
  tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
);

void main() {
  late LooperRepository repository;
  late StreamController<LooperState> stateController;

  setUpAll(() => registerFallbackValue(QuantizeMode.bar));

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
      () => repository.stopTrack(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.play(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.clear(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.undo(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.redo(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setVolume(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setTempo(any())).thenReturn(EngineResult.ok);
    when(
      () => repository.setMetronome(on: any(named: 'on')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setCountIn(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(repository.tapTempo).thenReturn(EngineResult.ok);
    when(
      () => repository.setSyncTempo(on: any(named: 'on')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setQuantize(any())).thenReturn(EngineResult.ok);
  });

  tearDown(() => stateController.close());

  LooperBloc buildBloc() => LooperBloc(repository: repository);

  test('initial state is an empty looper', () {
    final bloc = buildBloc();
    addTearDown(bloc.close);
    expect(bloc.state, const LooperState());
  });

  blocTest<LooperBloc, LooperState>(
    'emits repository states pushed through the stream',
    build: buildBloc,
    act: (_) => stateController.add(_playingState),
    expect: () => [_playingState],
  );

  blocTest<LooperBloc, LooperState>(
    'LooperRecordPressed forwards to repository.record with the channel',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperRecordPressed(2)),
    verify: (_) => verify(() => repository.record(channel: 2)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperStopPressed forwards to repository.stopTrack',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperStopPressed(1)),
    verify: (_) => verify(() => repository.stopTrack(channel: 1)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperRedoPressed forwards to repository.redo with the channel',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperRedoPressed(2)),
    verify: (_) => verify(() => repository.redo(channel: 2)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperVolumeChanged forwards the new volume and channel',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperVolumeChanged(3, 0.5)),
    verify: (_) =>
        verify(() => repository.setVolume(0.5, channel: 3)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperMuteToggled mutes from the current (unmuted) state',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperMuteToggled(0)),
    verify: (_) => verify(() => repository.setMute(muted: true)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperPlayAllPressed plays every track with content',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(state: TrackState.playing, lengthFrames: 100),
        Track(channel: 1, lengthFrames: 100, state: TrackState.stopped),
        Track(channel: 2), // empty -> skipped
      ],
    ),
    act: (bloc) => bloc.add(const LooperPlayAllPressed()),
    verify: (_) {
      verify(() => repository.play()).called(1);
      verify(() => repository.play(channel: 1)).called(1);
      verifyNever(() => repository.play(channel: 2));
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperTempoChanged forwards the new tempo',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperTempoChanged(140)),
    verify: (_) => verify(() => repository.setTempo(140)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperMetronomeToggled enables the metronome from off',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperMetronomeToggled()),
    verify: (_) => verify(() => repository.setMetronome(on: true)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperCountInToggled enables count-in from off',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperCountInToggled()),
    verify: (_) => verify(() => repository.setCountIn(enabled: true)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperTapTempo forwards to repository.tapTempo',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperTapTempo()),
    verify: (_) => verify(repository.tapTempo).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperSyncTempoToggled disables loop-to-tempo sync from the default on',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperSyncTempoToggled()),
    verify: (_) => verify(() => repository.setSyncTempo(on: false)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperQuantizeChanged forwards the mode to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperQuantizeChanged(QuantizeMode.beat)),
    verify: (_) =>
        verify(() => repository.setQuantize(QuantizeMode.beat)).called(1),
  );

  group('controller wiring', () {
    late _FakeControllerSource source;
    late ControllerRepository controller;

    setUp(() {
      source = _FakeControllerSource();
      controller = ControllerRepository(sources: [source]);
    });

    tearDown(() => controller.dispose());

    test('a mapped controller press drives the repository', () async {
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      // Default mapping: CC 80 -> recordOverdub on channel 0.
      source.press(ControllerSourceKind.midiCc, 80);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(() => repository.record()).called(1);
    });

    test('a mapped tap-tempo press drives the repository', () async {
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      // Default mapping: CC 84 -> tapTempo.
      source.press(ControllerSourceKind.midiCc, 84);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(repository.tapTempo).called(1);
    });
  });
}
