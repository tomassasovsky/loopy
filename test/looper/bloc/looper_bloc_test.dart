import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

const _playingState = LooperState(
  transport: TransportState(isRunning: true, masterLengthFrames: 48000),
  track: Track(state: TrackState.playing, lengthFrames: 48000),
);

void main() {
  late LooperRepository repository;
  late StreamController<LooperState> stateController;

  setUp(() {
    repository = _MockLooperRepository();
    stateController = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => stateController.stream);
    when(repository.record).thenReturn(EngineResult.ok);
    when(repository.stopTrack).thenReturn(EngineResult.ok);
    when(repository.play).thenReturn(EngineResult.ok);
    when(repository.clear).thenReturn(EngineResult.ok);
    when(repository.undo).thenReturn(EngineResult.ok);
    when(() => repository.setVolume(any())).thenReturn(EngineResult.ok);
    when(
      () => repository.setMute(muted: any(named: 'muted')),
    ).thenReturn(EngineResult.ok);
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
    'LooperRecordPressed forwards to repository.record',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperRecordPressed()),
    verify: (_) => verify(repository.record).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperStopPressed forwards to repository.stopTrack',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperStopPressed()),
    verify: (_) => verify(repository.stopTrack).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperPlayPressed forwards to repository.play',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperPlayPressed()),
    verify: (_) => verify(repository.play).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperClearPressed forwards to repository.clear',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperClearPressed()),
    verify: (_) => verify(repository.clear).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperUndoPressed forwards to repository.undo',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperUndoPressed()),
    verify: (_) => verify(repository.undo).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperVolumeChanged forwards the new volume',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperVolumeChanged(0.5)),
    verify: (_) => verify(() => repository.setVolume(0.5)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperMuteToggled mutes from the current (unmuted) state',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperMuteToggled()),
    verify: (_) => verify(() => repository.setMute(muted: true)).called(1),
  );
}
