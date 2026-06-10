import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

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
    when(
      () => repository.setInputMask(
        channel: any(named: 'channel'),
        mask: any(named: 'mask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setOutputMask(
        channel: any(named: 'channel'),
        mask: any(named: 'mask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setTrackQuantize(
        channel: any(named: 'channel'),
        enabled: any(named: 'enabled'),
      ),
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
    'LooperInputMaskChanged forwards channel and mask to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperInputMaskChanged(2, 0x3)),
    verify: (_) =>
        verify(() => repository.setInputMask(channel: 2, mask: 0x3)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperOutputMaskChanged forwards channel and mask to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperOutputMaskChanged(1, 0x5)),
    verify: (_) =>
        verify(() => repository.setOutputMask(channel: 1, mask: 0x5)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperTrackQuantizeChanged forwards the override to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperTrackQuantizeChanged(2, enabled: true)),
    verify: (_) => verify(
      () => repository.setTrackQuantize(channel: 2, enabled: true),
    ).called(1),
  );

  group('routing persistence', () {
    late SettingsRepository settings;

    setUp(() {
      settings = _MockSettingsRepository();
      when(
        () => settings.saveTrackInputMask(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveTrackOutputMask(any(), any()),
      ).thenAnswer((_) async {});
    });

    blocTest<LooperBloc, LooperState>(
      'LooperInputMaskChanged persists the input mask',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) => bloc.add(const LooperInputMaskChanged(3, 0x3)),
      verify: (_) {
        verify(
          () => repository.setInputMask(channel: 3, mask: 0x3),
        ).called(1);
        verify(() => settings.saveTrackInputMask(3, 0x3)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperOutputMaskChanged persists the output mask',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) => bloc.add(const LooperOutputMaskChanged(0, 0x6)),
      verify: (_) {
        verify(() => repository.setOutputMask(channel: 0, mask: 0x6)).called(1);
        verify(() => settings.saveTrackOutputMask(0, 0x6)).called(1);
      },
    );
  });

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
    'LooperClearAllPressed clears every track that has content',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(state: TrackState.playing, lengthFrames: 100),
        Track(channel: 1), // empty -> skipped
      ],
    ),
    act: (bloc) => bloc.add(const LooperClearAllPressed()),
    verify: (_) {
      verify(() => repository.clear()).called(1);
      verifyNever(() => repository.clear(channel: 1));
    },
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
  });
}
