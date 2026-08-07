import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:segno_engine/segno_engine.dart' as le show LatencyState;
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
    when(() => repository.laneChainEnabled(any(), any())).thenReturn(true);
    when(
      () => repository.laneChainInheritedFrom(any(), any()),
    ).thenReturn(const []);
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
    'LooperAllOneShotToggled sweeps every track the repository is holding, '
    'from the repository snapshot rather than the bloc state — the console '
    "switch's whole point is that no half-applied sweep is observable",
    build: () {
      when(() => repository.state).thenReturn(
        const LooperState(
          tracks: [
            Track(oneShot: true),
            Track(channel: 1),
            Track(channel: 2, oneShot: true),
          ],
        ),
      );
      return buildBloc();
    },
    act: (bloc) => bloc.add(const LooperAllOneShotToggled(oneShot: true)),
    verify: (_) {
      for (final channel in [0, 1, 2]) {
        verify(
          () => repository.setOneShot(channel: channel, oneShot: true),
        ).called(1);
      }
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperAllOneShotToggled carries the flag it was given — clearing the '
    'switch clears every track, it does not toggle each one',
    build: () {
      when(() => repository.state).thenReturn(
        const LooperState(
          tracks: [Track(oneShot: true), Track(channel: 1, oneShot: true)],
        ),
      );
      return buildBloc();
    },
    act: (bloc) => bloc.add(const LooperAllOneShotToggled(oneShot: false)),
    verify: (_) {
      verify(
        () => repository.setOneShot(channel: 0, oneShot: false),
      ).called(1);
      verify(
        () => repository.setOneShot(channel: 1, oneShot: false),
      ).called(1);
      verifyNever(
        () => repository.setOneShot(
          channel: any(named: 'channel'),
          oneShot: true,
        ),
      );
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperAllOneShotToggled with no tracks writes nothing',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperAllOneShotToggled(oneShot: true)),
    verify: (_) => verifyNever(
      () => repository.setOneShot(
        channel: any(named: 'channel'),
        oneShot: any(named: 'oneShot'),
      ),
    ),
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
          () => settings.saveLaneEffects(
            0,
            1,
            encodeFxChain(FxChainEnvelope(entries: takeChain)),
          ),
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
        final decoded = decodeFxChain(encoded).entries.single as PluginEffect;
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

    group('track/master chain events (FX v3 part 3a)', () {
      final trackChain = [BuiltInEffect(type: TrackEffectType.delay)];
      final masterChain = [BuiltInEffect(type: TrackEffectType.reverb)];

      setUp(() {
        when(
          () => repository.setTrackEffects(
            channel: any(named: 'channel'),
            effects: any(named: 'effects'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setTrackEffectEnabled(
            channel: any(named: 'channel'),
            index: any(named: 'index'),
            enabled: any(named: 'enabled'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setTrackChainEnabled(
            channel: any(named: 'channel'),
            enabled: any(named: 'enabled'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setMasterEffects(
            effects: any(named: 'effects'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setMasterEffectEnabled(
            index: any(named: 'index'),
            enabled: any(named: 'enabled'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setMasterChainEnabled(
            enabled: any(named: 'enabled'),
          ),
        ).thenReturn(EngineResult.ok);
        when(() => repository.trackEffects(any())).thenReturn(trackChain);
        when(() => repository.trackChainEnabled(any())).thenReturn(false);
        when(() => repository.masterEffects).thenReturn(masterChain);
        when(() => repository.masterChainEnabled).thenReturn(false);
        when(
          () => settings.saveTrackFxChain(any(), any()),
        ).thenAnswer((_) async {});
        when(
          () => settings.saveMasterFxChain(any()),
        ).thenAnswer((_) async {});
      });

      blocTest<LooperBloc, LooperState>(
        'LooperTrackEffectsChanged pushes the chain and persists the '
        'envelope with the repo chain flag',
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(LooperTrackEffectsChanged(1, trackChain)),
        verify: (_) {
          verify(
            () => repository.setTrackEffects(channel: 1, effects: trackChain),
          ).called(1);
          final encoded =
              verify(
                    () => settings.saveTrackFxChain(1, captureAny()),
                  ).captured.single
                  as String;
          final decoded = decodeFxChain(encoded);
          expect(decoded.entries, trackChain);
          expect(decoded.chainEnabled, isFalse); // the repo flag rode along
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus add-of-type composes from the repository, so an add and a '
        'retype dispatched together do not clobber each other',
        setUp: () {
          // The repository is the authority each handler composes from; the
          // fake starts empty and accumulates, exactly like the real one.
          var chain = <TrackEffect>[];
          when(() => repository.trackEffects(0)).thenAnswer((_) => chain);
          when(
            () => repository.setTrackEffects(
              channel: any(named: 'channel'),
              effects: any(named: 'effects'),
            ),
          ).thenAnswer((invocation) {
            chain = invocation.namedArguments[#effects] as List<TrackEffect>;
            return EngineResult.ok;
          });
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc
          ..add(
            const LooperBusEffectAdded(
              FxAddress(stage: FxStage.track),
              type: TrackEffectType.reverb,
            ),
          )
          ..add(
            const LooperBusEffectAdded(
              FxAddress(stage: FxStage.track),
              type: TrackEffectType.echo,
            ),
          ),
        verify: (_) {
          final pushes = verify(
            () => repository.setTrackEffects(
              channel: 0,
              effects: captureAny(named: 'effects'),
            ),
          ).captured.cast<List<TrackEffect>>();
          // Both adds landed, each carrying its own picked type — the second
          // did not overwrite the first from a stale base.
          expect(pushes.last, hasLength(2));
          expect(
            pushes.last.map((fx) => (fx as BuiltInEffect).type),
            [TrackEffectType.reverb, TrackEffectType.echo],
          );
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus edit on the master stage writes the Master insert',
        setUp: () {
          when(
            () => repository.masterEffects,
          ).thenReturn([BuiltInEffect(type: TrackEffectType.drive)]);
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(
          const LooperBusEffectTypeChanged(
            FxAddress(stage: FxStage.master),
            0,
            TrackEffectType.reverb,
          ),
        ),
        verify: (_) {
          final pushed =
              verify(
                    () => repository.setMasterEffects(
                      effects: captureAny(named: 'effects'),
                    ),
                  ).captured.single
                  as List<TrackEffect>;
          expect(
            (pushed.single as BuiltInEffect).type,
            TrackEffectType.reverb,
          );
          verify(() => settings.saveMasterFxChain(any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus retype keeps the slot powered off and keeps its id',
        setUp: () {
          when(() => repository.trackEffects(0)).thenReturn([
            BuiltInEffect(
              type: TrackEffectType.drive,
              enabled: false,
              slotId: 'slot-a',
            ),
          ]);
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(
          const LooperBusEffectTypeChanged(
            FxAddress(stage: FxStage.track),
            0,
            TrackEffectType.reverb,
          ),
        ),
        verify: (_) {
          final pushed =
              verify(
                    () => repository.setTrackEffects(
                      channel: 0,
                      effects: captureAny(named: 'effects'),
                    ),
                  ).captured.single
                  as List<TrackEffect>;
          final fx = pushed.single as BuiltInEffect;
          expect(fx.type, TrackEffectType.reverb);
          // A retype changes the device, not the power decision or the identity
          // bindings target (D-POWER/R23, A9).
          expect(fx.enabled, isFalse);
          expect(fx.slotId, 'slot-a');
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus relink keeps the persisted state, tweaks and power flag',
        setUp: () {
          when(() => repository.masterEffects).thenReturn([
            const PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'old', version: 1),
              paramValues: {3: 0.8},
              state: 'blob',
              enabled: false,
              slotId: 'slot-b',
              unavailable: true,
              unsupported: true,
            ),
          ]);
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(
          const LooperBusPluginRelinked(
            FxAddress(stage: FxStage.master),
            0,
            PluginRef(format: PluginFormat.vst3, id: 'new', version: 2),
          ),
        ),
        verify: (_) {
          final pushed =
              verify(
                    () => repository.setMasterEffects(
                      effects: captureAny(named: 'effects'),
                    ),
                  ).captured.single
                  as List<TrackEffect>;
          final fx = pushed.single as PluginEffect;
          expect(fx.ref.id, 'new');
          // Relink is the ONLY action a bus plugin offers, so it must not be
          // the thing that destroys what the user saved.
          expect(fx.state, 'blob');
          expect(fx.paramValues, {3: 0.8});
          expect(fx.enabled, isFalse);
          expect(fx.slotId, 'slot-b');
          expect(fx.unavailable, isFalse);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus param change goes through the granular setter, not a re-push',
        setUp: () {
          when(() => repository.trackEffects(0)).thenReturn([
            BuiltInEffect(type: TrackEffectType.reverb),
          ]);
          when(
            () => repository.setTrackEffectParam(
              channel: any(named: 'channel'),
              index: any(named: 'index'),
              param: any(named: 'param'),
              value: any(named: 'value'),
            ),
          ).thenReturn(EngineResult.ok);
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(
          const LooperBusEffectParamChanged(
            FxAddress(stage: FxStage.track),
            0,
            1,
            0.25,
          ),
        ),
        verify: (_) {
          verify(
            () => repository.setTrackEffectParam(
              channel: 0,
              index: 0,
              param: 1,
              value: 0.25,
            ),
          ).called(1);
          // A whole-chain push would re-send every slot's TYPE, and the engine
          // resets a slot's DSP on every type push — so a knob drag would clear
          // the bus's reverb tails and delay lines at pointer-move rate.
          verifyNever(
            () => repository.setTrackEffects(
              channel: any(named: 'channel'),
              effects: any(named: 'effects'),
            ),
          );
          verify(() => settings.saveTrackFxChain(0, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a re-sync cancels the lane editor polls it would otherwise rebind',
        setUp: () {
          when(
            () => repository.resyncLaneChainFromInput(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
            ),
          ).thenReturn(true);
          when(
            () => repository.isLanePluginEditorOpen(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
              index: any(named: 'index'),
            ),
          ).thenReturn(true);
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) async {
          bloc.add(const LooperLanePluginEditorOpened(0, 0, 0));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          bloc.add(const LooperLaneChainResyncedFromInput(0, 0));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        },
        verify: (_) {
          // The poll must stop at the re-sync: the chain it was keyed to is
          // gone, so continuing would rebind it to whatever lands at that
          // index. Without the cancel it keeps ticking (~10 Hz).
          verify(
            () => repository.resyncLaneChainFromInput(channel: 0, lane: 0),
          ).called(1);
          verifyNever(
            () => repository.refreshLanePluginParams(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
              index: any(named: 'index'),
            ),
          );
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus edit past the end of the chain is ignored',
        setUp: () =>
            when(() => repository.trackEffects(0)).thenReturn(const []),
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(
          const LooperBusEffectRemoved(FxAddress(stage: FxStage.track), 3),
        ),
        verify: (_) {
          verifyNever(
            () => repository.setTrackEffects(
              channel: any(named: 'channel'),
              effects: any(named: 'effects'),
            ),
          );
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperLaneEffectEnabledToggled flips the slot and re-persists',
        setUp: () {
          when(
            () => repository.setLaneEffectEnabled(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
              index: any(named: 'index'),
              enabled: any(named: 'enabled'),
            ),
          ).thenReturn(EngineResult.ok);
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(
          const LooperLaneEffectEnabledToggled(0, 1, 2, enabled: false),
        ),
        verify: (_) {
          verify(
            () => repository.setLaneEffectEnabled(
              channel: 0,
              lane: 1,
              index: 2,
              enabled: false,
            ),
          ).called(1);
          verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperLaneChainEnabledToggled flips the chain flag and re-persists',
        setUp: () {
          when(
            () => repository.setLaneChainEnabled(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
              enabled: any(named: 'enabled'),
            ),
          ).thenReturn(EngineResult.ok);
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) =>
            bloc.add(const LooperLaneChainEnabledToggled(0, 1, enabled: false)),
        verify: (_) {
          verify(
            () => repository.setLaneChainEnabled(
              channel: 0,
              lane: 1,
              enabled: false,
            ),
          ).called(1);
          verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperLaneChainResyncedFromInput re-copies the routed input chain',
        setUp: () {
          when(
            () => repository.resyncLaneChainFromInput(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
            ),
          ).thenReturn(true);
        },
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(const LooperLaneChainResyncedFromInput(0, 1)),
        verify: (_) {
          // Explicit and user initiated (A6) — the repository owns the copy and
          // notifies back for persistence, so the bloc adds no second write.
          verify(
            () => repository.resyncLaneChainFromInput(channel: 0, lane: 1),
          ).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperTrackEffectEnabledToggled flips the slot and re-persists',
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(
          const LooperTrackEffectEnabledToggled(0, 1, enabled: false),
        ),
        verify: (_) {
          verify(
            () => repository.setTrackEffectEnabled(
              channel: 0,
              index: 1,
              enabled: false,
            ),
          ).called(1);
          verify(() => settings.saveTrackFxChain(0, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperTrackChainEnabledToggled flips the chain flag and '
        're-persists',
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) =>
            bloc.add(const LooperTrackChainEnabledToggled(2, enabled: false)),
        verify: (_) {
          verify(
            () => repository.setTrackChainEnabled(channel: 2, enabled: false),
          ).called(1);
          verify(() => settings.saveTrackFxChain(2, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperMasterEffectsChanged pushes the chain and persists the '
        'envelope',
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(LooperMasterEffectsChanged(masterChain)),
        verify: (_) {
          verify(
            () => repository.setMasterEffects(effects: masterChain),
          ).called(1);
          final encoded =
              verify(
                    () => settings.saveMasterFxChain(captureAny()),
                  ).captured.single
                  as String;
          expect(decodeFxChain(encoded).entries, masterChain);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperMasterEffectEnabledToggled flips the slot and re-persists',
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) => bloc.add(
          const LooperMasterEffectEnabledToggled(0, enabled: false),
        ),
        verify: (_) {
          verify(
            () => repository.setMasterEffectEnabled(index: 0, enabled: false),
          ).called(1);
          verify(() => settings.saveMasterFxChain(any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperMasterChainEnabledToggled flips the chain flag and '
        're-persists',
        build: () => LooperBloc(repository: repository, settings: settings),
        act: (bloc) =>
            bloc.add(const LooperMasterChainEnabledToggled(enabled: false)),
        verify: (_) {
          verify(
            () => repository.setMasterChainEnabled(enabled: false),
          ).called(1);
          verify(() => settings.saveMasterFxChain(any())).called(1);
        },
      );
    });

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

  group('restoreLooperMode() (B5c boot restore)', () {
    late SettingsRepository settings;

    setUp(() {
      settings = _MockSettingsRepository();
      when(() => settings.saveLooperMode(any())).thenAnswer((_) async {});
    });

    test(
      'dispatches the persisted looper mode as a LooperModeChanged event '
      "(a free function, not a bloc method — bloc_lint's "
      'avoid_public_bloc_methods)',
      () async {
        when(() => settings.loadLooperMode()).thenAnswer((_) async => 2);
        final bloc = LooperBloc(repository: repository, settings: settings);
        addTearDown(bloc.close);

        await restoreLooperMode(bloc, settings);
        // bloc.add() only enqueues the event; the on<LooperModeChanged>
        // handler runs on a later microtask via the bloc package's internal
        // event transformer — yield once so it has actually run before
        // asserting its effect.
        await Future<void>.delayed(Duration.zero);

        // Code 2 == LooperMode.song (engine_snapshot.dart's code mapping).
        verify(() => repository.setLooperMode(LooperMode.song)).called(1);
      },
    );

    test('defaults to Multi when nothing was ever persisted', () async {
      when(() => settings.loadLooperMode()).thenAnswer((_) async => 0);
      final bloc = LooperBloc(repository: repository, settings: settings);
      addTearDown(bloc.close);

      await restoreLooperMode(bloc, settings);
      await Future<void>.delayed(Duration.zero);

      verify(() => repository.setLooperMode(LooperMode.multi)).called(1);
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

  // A REAL repository over the fake engine, not the mock the rest of this file
  // uses: the resync reads the repository's own chain enumerations and writes
  // real envelopes, so stubbing them would assert the fixture instead of the
  // encoding — and the shrink case is about a key the enumeration OMITS, which
  // a stub cannot express honestly.
  group('LooperSessionLoaded', () {
    late FakeAudioEngine engine;
    late LooperRepository looper;
    late SettingsRepository settings;
    late LooperBloc bloc;

    setUp(() {
      engine = FakeAudioEngine()
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty(), TrackSnapshot.empty()],
        );
      looper = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      )..startEngine(const EngineConfig());
      settings = SettingsRepository(store: FakeKeyValueStore());
      bloc = LooperBloc(repository: looper, settings: settings);
    });

    tearDown(() async {
      await bloc.close();
      await looper.dispose();
    });

    /// Dispatches the resync and lets the bloc's event stream drain.
    Future<void> resync() async {
      bloc.add(const LooperSessionLoaded());
      await pumpEventQueue();
    }

    test(
      'persists the chains the repository holds, on all three stages',
      () async {
        looper
          ..setLaneEffects(
            channel: 0,
            lane: 1,
            effects: [BuiltInEffect(type: TrackEffectType.drive)],
          )
          ..setTrackEffects(
            channel: 1,
            effects: [BuiltInEffect(type: TrackEffectType.reverb)],
          )
          ..setMasterEffects(
            effects: [BuiltInEffect(type: TrackEffectType.delay)],
          );

        await resync();

        expect(
          decodeFxChain(await settings.loadLaneEffects(0, 1)).entries.single,
          isA<BuiltInEffect>().having(
            (e) => e.type,
            'type',
            TrackEffectType.drive,
          ),
        );
        expect(
          decodeFxChain(await settings.loadTrackFxChain(1)).entries.single,
          isA<BuiltInEffect>().having(
            (e) => e.type,
            'type',
            TrackEffectType.reverb,
          ),
        );
        expect(
          decodeFxChain(await settings.loadMasterFxChain()).entries.single,
          isA<BuiltInEffect>().having(
            (e) => e.type,
            'type',
            TrackEffectType.delay,
          ),
        );
      },
    );

    test('persists the chain-enabled flag inside the envelope, not just the '
        'entries', () async {
      looper
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setLaneChainEnabled(channel: 0, lane: 0, enabled: false)
        ..setMasterChainEnabled(enabled: false);

      await resync();

      expect(
        decodeFxChain(await settings.loadLaneEffects(0, 0)).chainEnabled,
        isFalse,
      );
      expect(
        decodeFxChain(await settings.loadMasterFxChain()).chainEnabled,
        isFalse,
      );
    });

    test('persists the slot ids the load minted, so a pedal binding stored '
        'against one survives a restart', () async {
      looper.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      final live = looper.laneEffects(0, 0).single.slotId;

      await resync();

      expect(live, isNotNull);
      expect(
        decodeFxChain(
          await settings.loadLaneEffects(0, 0),
        ).entries.single.slotId,
        live,
      );
    });

    test('CLEARS the keys a shrinking load dropped, rather than leaving them '
        'stale', () async {
      // The pre-load rig, persisted through the edit paths.
      bloc
        ..add(const LooperLaneEffectAdded(0, 0, type: TrackEffectType.drive))
        ..add(
          LooperTrackEffectsChanged(0, [
            BuiltInEffect(type: TrackEffectType.reverb),
          ]),
        );
      await pumpEventQueue();
      expect(await settings.loadLaneEffects(0, 0), isNotNull);
      expect(await settings.loadTrackFxChain(0), isNotNull);

      // The loaded session defines neither chain: the repository drops both,
      // so the enumerations omit them and there is no envelope to overwrite
      // the keys with.
      looper
        ..setLaneEffects(channel: 0, lane: 0, effects: const [])
        ..setTrackEffects(channel: 0, effects: const []);

      await resync();

      expect(await settings.loadLaneEffects(0, 0), isNull);
      expect(await settings.loadTrackFxChain(0), isNull);
    });

    test('is a no-op without a settings dependency', () async {
      final blocWithoutSettings = LooperBloc(repository: looper);
      addTearDown(blocWithoutSettings.close);
      looper.setMasterEffects(
        effects: [BuiltInEffect(type: TrackEffectType.delay)],
      );

      blocWithoutSettings.add(const LooperSessionLoaded());
      await pumpEventQueue();

      expect(await settings.loadMasterFxChain(), isNull);
    });
  });
}
