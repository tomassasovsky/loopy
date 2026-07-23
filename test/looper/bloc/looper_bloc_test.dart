import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

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

  setUpAll(() {
    registerFallbackValue(<TrackEffect>[]);
    registerFallbackValue(const PluginRef(format: PluginFormat.vst3, id: ''));
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(LooperMode.multi);
  });

  setUp(() {
    repository = _MockLooperRepository();
    stateController = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => stateController.stream);
    // A fresh synchronous snapshot read, distinct from the bloc's own
    // (stream-driven) `state` — `_cancelPendingArms` reads this directly
    // (narrows the cancel-arm TOCTOU race; see its doc). Defaults to no
    // tracks; per-test overrides stub a pending track set.
    when(() => repository.state).thenReturn(const LooperState());
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
      () => repository.setTrackLengthPreset(
        channel: any(named: 'channel'),
        bars: any(named: 'bars'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setOneShot(
        channel: any(named: 'channel'),
        oneShot: any(named: 'oneShot'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.crownPrimary(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setLooperMode(any())).thenReturn(EngineResult.ok);
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
    when(
      () => repository.relinkLanePlugin(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        ref: any(named: 'ref'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.laneEffects(any(), any())).thenReturn(const []);
    when(
      () => repository.setOutputEnabled(
        output: any(named: 'output'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(repository.tapTempo).thenReturn(EngineResult.ok);
    when(() => repository.setClickMode(any())).thenReturn(EngineResult.ok);
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
    'LooperUndoPressed on a base-loop track undoes (never clears): the '
    'engine empties it redo-ably',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(),
        Track(channel: 1, state: TrackState.playing, lengthFrames: 100),
      ],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.undo(channel: 1)).called(1);
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
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
    'LooperClearPressed clears the track and re-arms it (unmutes)',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(state: TrackState.stopped, lengthFrames: 100, muted: true),
      ],
    ),
    act: (bloc) => bloc.add(const LooperClearPressed(0)),
    verify: (_) {
      verify(() => repository.clear()).called(1);
      verify(() => repository.setMute(muted: false)).called(1);
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperUndoPressed on a muted base-loop track still undoes — the mute '
    'is untouched (undo/redo are exact inverses)',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(),
        Track(
          channel: 1,
          state: TrackState.stopped,
          lengthFrames: 100,
          muted: true,
        ),
      ],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.undo(channel: 1)).called(1);
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
      verifyNever(
        () => repository.setMute(
          muted: any(named: 'muted'),
          channel: any(named: 'channel'),
        ),
      );
    },
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
    'LooperTrackLengthPresetChanged forwards bars to the repository',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperTrackLengthPresetChanged(1, 8)),
    verify: (_) => verify(
      () => repository.setTrackLengthPreset(channel: 1, bars: 8),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperOneShotToggled forwards the flag to the repository (B5c)',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperOneShotToggled(1, oneShot: true)),
    verify: (_) => verify(
      () => repository.setOneShot(channel: 1, oneShot: true),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperCrownPrimaryPressed forwards the channel to the repository (D18, '
    'B5c)',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperCrownPrimaryPressed(2)),
    verify: (_) => verify(() => repository.crownPrimary(channel: 2)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperModeChanged forwards the mode to the repository (D4, B5c) — '
    "the confirmation flow is the UI's job, not the bloc's",
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperModeChanged(LooperMode.band)),
    verify: (_) =>
        verify(() => repository.setLooperMode(LooperMode.band)).called(1),
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

  blocTest<LooperBloc, LooperState>(
    'LooperLanePluginInserted appends a PluginEffect to the lane chain',
    build: buildBloc,
    act: (bloc) => bloc.add(
      const LooperLanePluginInserted(
        1,
        0,
        PluginRef(format: PluginFormat.clap, id: 'com.acme.reverb'),
      ),
    ),
    verify: (_) {
      final effects =
          verify(
                () => repository.setLaneEffects(
                  channel: 1,
                  lane: 0,
                  effects: captureAny(named: 'effects'),
                ),
              ).captured.single
              as List<TrackEffect>;
      expect(
        effects.single,
        isA<PluginEffect>().having(
          (e) => e.ref.id,
          'ref.id',
          'com.acme.reverb',
        ),
      );
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLanePluginRelinked relinks the entry to the new ref',
    build: buildBloc,
    act: (bloc) => bloc.add(
      const LooperLanePluginRelinked(
        2,
        1,
        0,
        PluginRef(format: PluginFormat.vst3, id: 'replacement'),
      ),
    ),
    verify: (_) => verify(
      () => repository.relinkLanePlugin(
        channel: 2,
        lane: 1,
        index: 0,
        ref: const PluginRef(format: PluginFormat.vst3, id: 'replacement'),
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
      'LooperClearPressed persists the unmute so a cleared track stays armed',
      build: () => LooperBloc(repository: repository, settings: settings),
      seed: () => const LooperState(
        tracks: [
          Track(),
          Track(
            channel: 1,
            state: TrackState.stopped,
            lengthFrames: 100,
            muted: true,
          ),
        ],
      ),
      act: (bloc) => bloc.add(const LooperClearPressed(1)),
      verify: (_) {
        verify(() => repository.setMute(muted: false, channel: 1)).called(1);
        verify(() => settings.saveLaneMute(1, 0, muted: false)).called(1);
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
      'persists the take chain when the repository reports a record-time '
      'snapshot copy (F3)',
      build: () => LooperBloc(repository: repository, settings: settings),
      verify: (_) {
        // The bloc wires a chain-persist callback onto the repository; capture
        // it and simulate the record-time snapshot firing it.
        final callback =
            verify(
                  () => repository.onLaneChainChanged = captureAny(),
                ).captured.last
                as void Function(int, int)?;
        expect(callback, isNotNull);

        final takeChain = [BuiltInEffect(type: TrackEffectType.delay)];
        when(() => repository.laneEffects(0, 1)).thenReturn(takeChain);

        callback!(0, 1);
        verify(
          () => settings.saveLaneEffects(0, 1, encodeTrackEffects(takeChain)),
        ).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'inserting a plugin persists the chain enriched with its resolved name',
      build: () {
        // The repository resolves the display name while applying the chain;
        // the save must persist THAT enriched chain, not the name-less input —
        // else the name is lost on restart and the card shows the raw id.
        when(() => repository.laneEffects(1, 2)).thenReturn(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.clap, id: 'com.acme.reverb'),
            name: 'Acme Reverb',
          ),
        ]);
        return LooperBloc(repository: repository, settings: settings);
      },
      act: (bloc) => bloc.add(
        const LooperLanePluginInserted(
          1,
          2,
          PluginRef(format: PluginFormat.clap, id: 'com.acme.reverb'),
        ),
      ),
      verify: (_) {
        final encoded =
            verify(
                  () => settings.saveLaneEffects(1, 2, captureAny()),
                ).captured.single
                as String;
        final decoded = decodeTrackEffects(encoded).single as PluginEffect;
        expect(decoded.name, 'Acme Reverb');
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

    blocTest<LooperBloc, LooperState>(
      'LooperModeChanged persists the mode code (B5c)',
      build: () {
        when(() => settings.saveLooperMode(any())).thenAnswer((_) async {});
        return LooperBloc(repository: repository, settings: settings);
      },
      act: (bloc) => bloc.add(const LooperModeChanged(LooperMode.free)),
      verify: (_) {
        verify(() => repository.setLooperMode(LooperMode.free)).called(1);
        verify(() => settings.saveLooperMode(LooperMode.free.code)).called(1);
      },
    );
  });

  group('load() (B5c boot restore)', () {
    late SettingsRepository settings;

    setUp(() {
      settings = _MockSettingsRepository();
    });

    test('applies the persisted looper mode to the repository', () async {
      when(() => settings.loadLooperMode()).thenAnswer((_) async => 2);
      final bloc = LooperBloc(repository: repository, settings: settings);
      addTearDown(bloc.close);

      await bloc.load();

      // Code 2 == LooperMode.song (engine_snapshot.dart's code mapping).
      verify(() => repository.setLooperMode(LooperMode.song)).called(1);
    });

    test('is a no-op with no settings repository', () async {
      final bloc = buildBloc();
      addTearDown(bloc.close);

      await bloc.load(); // must not throw

      verifyNever(() => repository.setLooperMode(any()));
    });
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

    test(
      'play/playAll/stopAll drive the repository under a custom mapping '
      '(not in the built-in default)',
      () async {
        const kind = ControllerSourceKind.midiCc;
        final mapping = ControllerMapping.defaults().merge(
          const ControllerMapping(
            entries: [
              MappingEntry(
                trigger: MappingTrigger(kind: kind, id: 90),
                action: LooperAction.play,
              ),
              MappingEntry(
                trigger: MappingTrigger(kind: kind, id: 91),
                action: LooperAction.playAll,
              ),
              MappingEntry(
                trigger: MappingTrigger(kind: kind, id: 92),
                action: LooperAction.stopAll,
              ),
            ],
          ),
        );
        final customController = ControllerRepository(
          sources: [source],
          mapping: mapping,
        );
        addTearDown(customController.dispose);
        final bloc = LooperBloc(
          repository: repository,
          controller: customController,
        );
        addTearDown(bloc.close);

        source.press(kind, 90);
        await Future<void>.delayed(Duration.zero);
        source.press(kind, 91);
        await Future<void>.delayed(Duration.zero);
        source.press(kind, 92);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        verify(() => repository.play()).called(1);
      },
    );

    test('stop (CC 81) forwards to repository.stopTrack', () async {
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      source.press(ControllerSourceKind.midiCc, 81);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(() => repository.stopTrack()).called(1);
    });

    test('undo (CC 82) forwards to repository.undo', () async {
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      source.press(ControllerSourceKind.midiCc, 82);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(() => repository.undo()).called(1);
    });

    test('clear (CC 83) forwards to repository.clear', () async {
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      source.press(ControllerSourceKind.midiCc, 83);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(() => repository.clear()).called(1);
    });

    test('tapTempo (CC 84) forwards to repository.tapTempo', () async {
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      source.press(ControllerSourceKind.midiCc, 84);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(repository.tapTempo).called(1);
    });

    test('toggleMetronome (CC 85) turns the click on from off', () async {
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      source.press(ControllerSourceKind.midiCc, 85);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(() => repository.setClickMode(ClickMode.rec)).called(1);
    });

    test(
      'toggleMetronome (CC 85) turns the click back off when audible',
      () async {
        final bloc = LooperBloc(
          repository: repository,
          controller: controller,
        );
        addTearDown(bloc.close);
        // Posted after the bloc subscribes (stateController is a broadcast
        // stream — an earlier post would be missed).
        stateController.add(
          const LooperState(
            transport: TransportState(clickMode: ClickMode.playRec),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        source.press(ControllerSourceKind.midiCc, 85);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        verify(() => repository.setClickMode(ClickMode.off)).called(1);
      },
    );

    test('toggleMetronome persists the resulting mode via settings', () async {
      final settings = SettingsRepository(store: FakeKeyValueStore());
      final bloc = LooperBloc(
        repository: repository,
        controller: controller,
        settings: settings,
      );
      addTearDown(bloc.close);

      source.press(ControllerSourceKind.midiCc, 85);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(await settings.loadClickMode(), ClickMode.rec.code);
    });

    test(
      'cancelArm (CC 86) re-presses record on every pending track',
      () async {
        // _cancelPendingArms reads repository.state directly (a fresh
        // synchronous snapshot), not the bloc's own stream-driven state —
        // see its doc — so the pending set is stubbed there, not posted
        // through stateController.
        when(() => repository.state).thenReturn(
          const LooperState(
            tracks: [
              Track(pending: true),
              Track(channel: 1),
              Track(channel: 2, pending: true),
            ],
          ),
        );
        final bloc = LooperBloc(
          repository: repository,
          controller: controller,
        );
        addTearDown(bloc.close);

        source.press(ControllerSourceKind.midiCc, 86);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        verify(() => repository.record()).called(1);
        verify(() => repository.record(channel: 2)).called(1);
        verifyNever(() => repository.record(channel: 1));
      },
    );

    test(
      'cancelArm (CC 86) reads a fresh repository snapshot, not the '
      "bloc's own ~16ms-stale polled state (narrows the TOCTOU race)",
      () async {
        // The bloc's own (stream-driven) state says nothing is pending —
        // stale relative to the engine, as it would be mid-poll-interval.
        final bloc = LooperBloc(repository: repository, controller: controller);
        addTearDown(bloc.close);
        expect(bloc.state.tracks, isEmpty);
        // repository.state (a fresh synchronous engine read) says
        // otherwise. If cancelArm read `state.tracks` (the bloc's own,
        // stale) instead of `_repository.state.tracks`, this would find
        // nothing to cancel.
        when(
          () => repository.state,
        ).thenReturn(const LooperState(tracks: [Track(pending: true)]));

        source.press(ControllerSourceKind.midiCc, 86);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        verify(() => repository.record()).called(1);
      },
    );

    test('cancelArm (CC 86) is a no-op when nothing is pending', () async {
      // Default stub (setUp): repository.state has no tracks.
      final bloc = LooperBloc(repository: repository, controller: controller);
      addTearDown(bloc.close);

      source.press(ControllerSourceKind.midiCc, 86);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => repository.record(channel: any(named: 'channel')));
    });
  });
}
