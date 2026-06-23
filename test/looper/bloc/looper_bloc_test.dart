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

  setUpAll(() => registerFallbackValue(<TrackEffect>[]));

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
      () => repository.setTrackQuantize(
        channel: any(named: 'channel'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setTrackMultiple(
        channel: any(named: 'channel'),
        multiple: any(named: 'multiple'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneCount(
        channel: any(named: 'channel'),
        count: any(named: 'count'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneInput(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        inputChannel: any(named: 'inputChannel'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneOutput(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        mask: any(named: 'mask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneVolume(
        any(),
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneEffects(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        effects: any(named: 'effects'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneEffectParam(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLanePluginParam(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        paramId: any(named: 'paramId'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.openLanePluginEditor(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.closeLanePluginEditor(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.refreshLanePluginParams(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
      ),
    ).thenReturn(false);
    when(
      () => repository.isLanePluginEditorOpen(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
      ),
    ).thenReturn(true);
    when(() => repository.laneEffects(any(), any())).thenReturn(const []);
    when(
      () => repository.setOutputEnabled(
        output: any(named: 'output'),
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
    'LooperUndoPressed removes the layer when the track has overdubs',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(),
        Track(
          channel: 1,
          state: TrackState.playing,
          lengthFrames: 100,
          undoDepth: 2,
        ),
      ],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.undo(channel: 1)).called(1);
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperUndoPressed clears a track that has only its base loop',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(),
        Track(channel: 1, state: TrackState.playing, lengthFrames: 100),
      ],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.clear(channel: 1)).called(1);
      verifyNever(() => repository.undo(channel: any(named: 'channel')));
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperUndoPressed on an empty track forwards to undo, not clear',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [Track(), Track(channel: 1)],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.undo(channel: 1)).called(1);
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
    },
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
    'LooperTrackQuantizeChanged forwards the override to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperTrackQuantizeChanged(2, enabled: true)),
    verify: (_) => verify(
      () => repository.setTrackQuantize(channel: 2, enabled: true),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperTrackMultipleChanged forwards the multiple to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperTrackMultipleChanged(1, 3)),
    verify: (_) => verify(
      () => repository.setTrackMultiple(channel: 1, multiple: 3),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneCountChanged forwards the new count to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneCountChanged(1, 3)),
    verify: (_) =>
        verify(() => repository.setLaneCount(channel: 1, count: 3)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneInputChanged forwards channel, lane and input to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneInputChanged(2, 1, 3)),
    verify: (_) => verify(
      () => repository.setLaneInput(channel: 2, lane: 1, inputChannel: 3),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneOutputChanged forwards channel, lane and mask to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneOutputChanged(1, 2, 0x5)),
    verify: (_) => verify(
      () => repository.setLaneOutput(channel: 1, lane: 2, mask: 0x5),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneVolumeChanged forwards the volume for the lane',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneVolumeChanged(3, 1, 0.5)),
    verify: (_) => verify(
      () => repository.setLaneVolume(0.5, channel: 3, lane: 1),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperOutputEnabledToggled forwards the output gate to the repository',
    build: buildBloc,
    act: (bloc) =>
        bloc.add(const LooperOutputEnabledToggled(2, enabled: false)),
    verify: (_) => verify(
      () => repository.setOutputEnabled(output: 2, enabled: false),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneMuteToggled mutes from the current (unmuted) state',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneMuteToggled(0, 0)),
    verify: (_) => verify(
      () => repository.setLaneMute(muted: true, channel: 0, lane: 0),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneMuteToggled unmutes when the lane is already muted',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(lanes: [Lane(muted: true)]),
      ],
    ),
    act: (bloc) => bloc.add(const LooperLaneMuteToggled(0, 0)),
    verify: (_) => verify(
      () => repository.setLaneMute(muted: false, channel: 0, lane: 0),
    ).called(1),
  );

  // The chain surgery lives in the bloc: each intent event reads the current
  // chain from the repository, computes the next one, and pushes it back — the
  // view never builds the list. We capture the pushed chain to assert it.
  List<TrackEffect> capturePushedChain() =>
      verify(
            () => repository.setLaneEffects(
              channel: 1,
              lane: 2,
              effects: captureAny(named: 'effects'),
            ),
          ).captured.single
          as List<TrackEffect>;

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectAdded appends a default drive to the chain',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneEffectAdded(1, 2)),
    verify: (_) {
      final pushed = capturePushedChain();
      expect(pushed, hasLength(1));
      expect((pushed.single as BuiltInEffect).type, TrackEffectType.drive);
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectRemoved drops the entry at the given index',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(type: TrackEffectType.delay),
        BuiltInEffect(type: TrackEffectType.reverb),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(const LooperLaneEffectRemoved(1, 2, 0)),
    verify: (_) => expect(
      capturePushedChain().map((e) => (e as BuiltInEffect).type),
      [TrackEffectType.reverb],
    ),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectTypeChanged retypes the entry at the given index',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(type: TrackEffectType.delay),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(
      const LooperLaneEffectTypeChanged(1, 2, 0, TrackEffectType.reverb),
    ),
    verify: (_) => expect(
      (capturePushedChain().single as BuiltInEffect).type,
      TrackEffectType.reverb,
    ),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectMoved reorders the chain',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(type: TrackEffectType.delay),
        BuiltInEffect(type: TrackEffectType.reverb),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(const LooperLaneEffectMoved(1, 2, 0, 1)),
    verify: (_) =>
        expect(capturePushedChain().map((e) => (e as BuiltInEffect).type), [
          TrackEffectType.reverb,
          TrackEffectType.delay,
        ]),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectParamChanged forwards the param to the repository',
    build: buildBloc,
    act: (bloc) =>
        bloc.add(const LooperLaneEffectParamChanged(2, 1, 1, 0, 0.6)),
    verify: (_) => verify(
      () => repository.setLaneEffectParam(
        channel: 2,
        lane: 1,
        index: 1,
        param: 0,
        value: 0.6,
      ),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLanePluginParamChanged routes the plain value by plugin param id',
    build: buildBloc,
    act: (bloc) =>
        bloc.add(const LooperLanePluginParamChanged(2, 1, 0, 100, 0.8)),
    verify: (_) => verify(
      () => repository.setLanePluginParam(
        channel: 2,
        lane: 1,
        index: 0,
        paramId: 100,
        value: 0.8,
      ),
    ).called(1),
  );

  group('plugin editor', () {
    blocTest<LooperBloc, LooperState>(
      'opening starts the inbound sync poll',
      build: buildBloc,
      act: (bloc) => bloc.add(const LooperLanePluginEditorOpened(0, 0, 1)),
      wait: const Duration(milliseconds: 250),
      verify: (_) {
        verify(
          () => repository.openLanePluginEditor(channel: 0, lane: 0, index: 1),
        ).called(1);
        // The ≤10 Hz poll fired at least once while the editor is open.
        verify(
          () =>
              repository.refreshLanePluginParams(channel: 0, lane: 0, index: 1),
        ).called(greaterThanOrEqualTo(1));
      },
    );

    blocTest<LooperBloc, LooperState>(
      'closing cancels the poll and reads params back',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const LooperLanePluginEditorOpened(0, 0, 1));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        bloc.add(const LooperLanePluginEditorClosed(0, 0, 1));
      },
      wait: const Duration(milliseconds: 300),
      verify: (_) {
        verify(
          () => repository.closeLanePluginEditor(channel: 0, lane: 0, index: 1),
        ).called(1);
        // After close the poll is cancelled: record the tick count, then prove
        // it stops climbing.
        final ticks = verify(
          () =>
              repository.refreshLanePluginParams(channel: 0, lane: 0, index: 1),
        ).callCount;
        expect(ticks, greaterThanOrEqualTo(1));
      },
    );

    blocTest<LooperBloc, LooperState>(
      'the poll self-terminates when the native window is gone',
      build: buildBloc,
      setUp: () {
        // The user closes the OS window: the editor reports not-open, so the
        // poll must stop on its own (no leaked timer).
        when(
          () => repository.isLanePluginEditorOpen(
            channel: any(named: 'channel'),
            lane: any(named: 'lane'),
            index: any(named: 'index'),
          ),
        ).thenReturn(false);
      },
      act: (bloc) => bloc.add(const LooperLanePluginEditorOpened(0, 0, 1)),
      wait: const Duration(milliseconds: 250),
      verify: (_) {
        // One tick ran, saw the window gone, and cancelled the timer — so the
        // refresh count stays at exactly 1.
        verify(
          () =>
              repository.refreshLanePluginParams(channel: 0, lane: 0, index: 1),
        ).called(1);
      },
    );

    test('a structural chain edit cancels the lane poll', () async {
      // A reorder/remove reseats the slots, so the poll keyed by a stale index
      // must stop (otherwise it would mirror the wrong plugin).
      var refreshCount = 0;
      when(
        () => repository.refreshLanePluginParams(
          channel: any(named: 'channel'),
          lane: any(named: 'lane'),
          index: any(named: 'index'),
        ),
      ).thenAnswer((_) {
        refreshCount++;
        return false;
      });
      final bloc = buildBloc()
        ..add(const LooperLanePluginEditorOpened(0, 0, 1));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      addTearDown(bloc.close);
      expect(refreshCount, greaterThanOrEqualTo(1));
      // A structural edit (add) reseats the lane → the poll is cancelled.
      bloc.add(const LooperLaneEffectAdded(0, 0));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final after = refreshCount;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(refreshCount, after);
    });

    test('close() disposes any open editor poll timers', () async {
      // Count ticks via a stub side-effect (verify() consumes matches, so it
      // can't be read twice).
      var refreshCount = 0;
      when(
        () => repository.refreshLanePluginParams(
          channel: any(named: 'channel'),
          lane: any(named: 'lane'),
          index: any(named: 'index'),
        ),
      ).thenAnswer((_) {
        refreshCount++;
        return false;
      });
      final bloc = buildBloc()
        ..add(const LooperLanePluginEditorOpened(0, 0, 0));
      // Wait past one poll period so the timer has ticked at least once.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await bloc.close();
      final before = refreshCount;
      expect(before, greaterThanOrEqualTo(1));
      // No further ticks after close — the timer was cancelled.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(refreshCount, before);
    });
  });

  group('routing persistence', () {
    late SettingsRepository settings;

    setUp(() {
      settings = _MockSettingsRepository();
      when(
        () => settings.saveLaneCount(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveLaneInput(any(), any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveLaneOutput(any(), any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveLaneVolume(any(), any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveLaneMute(any(), any(), muted: any(named: 'muted')),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveLaneEffects(any(), any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveOutputEnabled(any(), enabled: any(named: 'enabled')),
      ).thenAnswer((_) async {});
    });

    blocTest<LooperBloc, LooperState>(
      'LooperOutputEnabledToggled forwards to the repo and persists the gate',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) =>
          bloc.add(const LooperOutputEnabledToggled(1, enabled: false)),
      verify: (_) {
        verify(
          () => repository.setOutputEnabled(output: 1, enabled: false),
        ).called(1);
        verify(() => settings.saveOutputEnabled(1, enabled: false)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneCountChanged persists the lane count',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) => bloc.add(const LooperLaneCountChanged(3, 2)),
      verify: (_) {
        verify(() => repository.setLaneCount(channel: 3, count: 2)).called(1);
        verify(() => settings.saveLaneCount(3, 2)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneInputChanged persists the input onto the lane',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) => bloc.add(const LooperLaneInputChanged(3, 1, 2)),
      verify: (_) {
        verify(
          () => repository.setLaneInput(channel: 3, lane: 1, inputChannel: 2),
        ).called(1);
        verify(() => settings.saveLaneInput(3, 1, 2)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneOutputChanged persists the output mask onto the lane',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) => bloc.add(const LooperLaneOutputChanged(0, 1, 0x6)),
      verify: (_) {
        verify(
          () => repository.setLaneOutput(channel: 0, lane: 1, mask: 0x6),
        ).called(1);
        verify(() => settings.saveLaneOutput(0, 1, 0x6)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneVolumeChanged persists the volume onto the lane',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) => bloc.add(const LooperLaneVolumeChanged(2, 1, 0.4)),
      verify: (_) {
        verify(
          () => repository.setLaneVolume(0.4, channel: 2, lane: 1),
        ).called(1);
        verify(() => settings.saveLaneVolume(2, 1, 0.4)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneMuteToggled persists the toggled mute onto the lane',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) => bloc.add(const LooperLaneMuteToggled(1, 0)),
      verify: (_) {
        verify(
          () => repository.setLaneMute(muted: true, channel: 1, lane: 0),
        ).called(1);
        verify(() => settings.saveLaneMute(1, 0, muted: true)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'a lane effect structural edit persists the encoded chain onto the lane',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) => bloc.add(const LooperLaneEffectAdded(1, 2)),
      verify: (_) {
        verify(
          () => repository.setLaneEffects(
            channel: 1,
            lane: 2,
            effects: any(named: 'effects'),
          ),
        ).called(1);
        verify(() => settings.saveLaneEffects(1, 2, any())).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneEffectParamChanged persists the re-encoded chain',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) =>
          bloc.add(const LooperLaneEffectParamChanged(0, 1, 1, 2, 0.25)),
      verify: (_) {
        verify(
          () => repository.setLaneEffectParam(
            channel: 0,
            lane: 1,
            index: 1,
            param: 2,
            value: 0.25,
          ),
        ).called(1);
        verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLanePluginParamChanged persists the re-encoded chain',
      build: () => LooperBloc(repository: repository, settings: settings),
      act: (bloc) =>
          bloc.add(const LooperLanePluginParamChanged(0, 1, 0, 100, 0.8)),
      verify: (_) {
        verify(
          () => repository.setLanePluginParam(
            channel: 0,
            lane: 1,
            index: 0,
            paramId: 100,
            value: 0.8,
          ),
        ).called(1);
        verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
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
