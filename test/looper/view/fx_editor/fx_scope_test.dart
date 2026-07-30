import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/fx_editor/fx_scope.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

LooperState _state({
  List<Track> tracks = const [],
  int inputChannels = 2,
  List<TrackEffect> masterEffects = const [],
}) => LooperState(
  tracks: tracks,
  masterEffects: masterEffects,
  status: EngineStatus(
    inputChannels: inputChannels,
    outputChannels: 2,
    isConnected: true,
  ),
);

void main() {
  late AppLocalizations l10n;
  late LooperBloc bloc;
  late LooperRepository repository;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
    registerFallbackValue(const LooperRecordPressed(0));
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
  });

  tearDown(() => repository.dispose());

  group('LaneFxScope', () {
    test('reads the live lane chain and its labels', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            Track(
              lanes: [
                Lane(effects: [BuiltInEffect(type: TrackEffectType.drive)]),
              ],
            ),
          ],
        ),
      );
      final scope = LaneFxScope(
        looper: bloc,
        repository: repository,
        track: 0,
        lane: 0,
      );

      expect(scope.isPresent, isTrue);
      expect(scope.effects, hasLength(1));
      expect(scope.label(l10n), l10n.laneNumberLabel(1));
      expect(scope.consequence(l10n), l10n.fxEditorLaneConsequence);
    });

    test('a removed lane index does not retarget a sibling lane', () {
      // The track has a single lane (index 0) carrying a drive. A scope keyed
      // to the now-gone lane 1 must read empty — never lane 0's chain.
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            Track(
              lanes: [
                Lane(effects: [BuiltInEffect(type: TrackEffectType.drive)]),
              ],
            ),
          ],
        ),
      );
      final scope = LaneFxScope(
        looper: bloc,
        repository: repository,
        track: 0,
        lane: 1,
      );

      expect(scope.isPresent, isFalse);
      expect(scope.effects, isEmpty);
    });

    test('edits dispatch keyed to its stable (track, lane)', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            const Track(lanes: [Lane()]),
          ],
        ),
      );
      LaneFxScope(
          looper: bloc,
          repository: repository,
          track: 0,
          lane: 0,
        )
        ..addEffect()
        ..removeEffect(2)
        ..moveEffect(1, 0)
        ..setType(0, TrackEffectType.reverb)
        ..setParam(0, 1, 0.5);

      verify(() => bloc.add(const LooperLaneEffectAdded(0, 0))).called(1);
      verify(() => bloc.add(const LooperLaneEffectRemoved(0, 0, 2))).called(1);
      verify(() => bloc.add(const LooperLaneEffectMoved(0, 0, 1, 0))).called(1);
      verify(
        () => bloc.add(
          const LooperLaneEffectTypeChanged(0, 0, 0, TrackEffectType.reverb),
        ),
      ).called(1);
      verify(
        () => bloc.add(const LooperLaneEffectParamChanged(0, 0, 0, 1, 0.5)),
      ).called(1);
    });

    test('plugin edits dispatch keyed to its stable (track, lane)', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            const Track(lanes: [Lane()]),
          ],
        ),
      );
      const ref = PluginRef(format: PluginFormat.vst3, id: 'abc');
      LaneFxScope(looper: bloc, repository: repository, track: 0, lane: 0)
        ..insertPlugin(ref)
        ..relinkPlugin(1, ref)
        ..setPluginParam(0, 7, 0.5)
        ..openPluginEditor(0);

      verify(
        () => bloc.add(const LooperLanePluginInserted(0, 0, ref)),
      ).called(1);
      verify(
        () => bloc.add(const LooperLanePluginRelinked(0, 0, 1, ref)),
      ).called(1);
      verify(
        () => bloc.add(const LooperLanePluginParamChanged(0, 0, 0, 7, 0.5)),
      ).called(1);
      verify(
        () => bloc.add(const LooperLanePluginEditorOpened(0, 0, 0)),
      ).called(1);
    });
  });

  group('InputFxScope', () {
    late MonitorCubit monitor;

    setUp(() {
      monitor = MonitorCubit(
        repository: repository,
        settings: SettingsRepository(store: FakeKeyValueStore()),
      );
    });

    tearDown(() => monitor.close());

    test('presence follows the engine channel count', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(),
      );
      final present = InputFxScope(
        monitor: monitor,
        looper: bloc,
        repository: repository,
        input: 1,
      );
      final absent = InputFxScope(
        monitor: monitor,
        looper: bloc,
        repository: repository,
        input: 5,
      );

      expect(present.isPresent, isTrue);
      expect(present.label(l10n), l10n.fxEditorInputTitle(2));
      expect(present.consequence(l10n), l10n.fxEditorInputConsequence);
      expect(absent.isPresent, isFalse);
      expect(absent.effects, isEmpty);
    });

    test('addEffect grows the live monitor chain', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(),
      );
      final scope = InputFxScope(
        monitor: monitor,
        looper: bloc,
        repository: repository,
        input: 0,
      );
      expect(scope.effects, isEmpty);

      scope.addEffect();

      expect(scope.effects, isNotEmpty);
    });
  });

  group('StageFxScope', () {
    StageFxScope trackScope(int channel) => StageFxScope(
      looper: bloc,
      address: FxAddress(stage: FxStage.track, index: channel),
    );

    StageFxScope masterScope() => StageFxScope(
      looper: bloc,
      address: const FxAddress(stage: FxStage.master),
    );

    test('the track stage reads that track bus chain and its labels', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            const Track(),
            Track(
              channel: 1,
              effects: [BuiltInEffect(type: TrackEffectType.reverb)],
              chainEnabled: false,
            ),
          ],
        ),
      );
      final scope = trackScope(1);

      expect(scope.isPresent, isTrue);
      expect(scope.address.stage, FxStage.track);
      expect(scope.effects, hasLength(1));
      expect(scope.chainEnabled, isFalse);
      expect(scope.label(l10n), l10n.fxEditorTrackTitle(2));
      expect(scope.consequence(l10n), l10n.fxEditorTrackConsequence);
      expect(
        scope.chainDisabledConsequence(l10n),
        l10n.fxChainOffTrackConsequence,
      );
    });

    test('the master stage reads the single insert chain, always present', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          masterEffects: [BuiltInEffect(type: TrackEffectType.drive)],
        ),
      );
      final scope = masterScope();

      // There is exactly one Master insert — no track has to exist for it.
      expect(scope.isPresent, isTrue);
      expect(scope.address.stage, FxStage.master);
      expect(scope.effects, hasLength(1));
      expect(scope.label(l10n), l10n.fxEditorMasterTitle);
      expect(
        scope.chainDisabledConsequence(l10n),
        l10n.fxChainOffMasterConsequence,
      );
    });

    test('a track index past the end reads empty, never a sibling', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            Track(effects: [BuiltInEffect(type: TrackEffectType.drive)]),
          ],
        ),
      );
      final scope = trackScope(3);

      expect(scope.isPresent, isFalse);
      expect(scope.effects, isEmpty);
    });

    test('an input or loop address is rejected — those have own scopes', () {
      // Throws rather than asserts: in a release build an unguarded input
      // address would silently be read as track channel 0 and edit the wrong
      // chain.
      expect(
        () => StageFxScope(
          looper: bloc,
          address: const FxAddress(stage: FxStage.input),
        ),
        throwsArgumentError,
      );
      expect(
        () => StageFxScope(
          looper: bloc,
          address: const FxAddress(stage: FxStage.loop, lane: 0),
        ),
        throwsArgumentError,
      );
    });

    test('structural edits dispatch INTENT, never a computed chain', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            Track(effects: [BuiltInEffect(type: TrackEffectType.drive)]),
          ],
        ),
      );
      const address = FxAddress(stage: FxStage.track);

      trackScope(0)
        ..addEffectOfType(TrackEffectType.reverb)
        ..removeEffect(0)
        ..moveEffect(1, 0)
        ..setType(0, TrackEffectType.echo)
        ..setParam(0, 1, 0.25);

      // The bloc composes each next chain from the repository while handling
      // the event; the scope reads `LooperState`, which lags every write by
      // that hop, so composing here would make two edits in one frame clobber
      // each other (concretely: add-then-retype).
      final events = verify(() => bloc.add(captureAny())).captured;
      expect(events, [
        const LooperBusEffectAdded(address, type: TrackEffectType.reverb),
        const LooperBusEffectRemoved(address, 0),
        const LooperBusEffectMoved(address, 1, 0),
        const LooperBusEffectTypeChanged(address, 0, TrackEffectType.echo),
        const LooperBusEffectParamChanged(address, 0, 1, 0.25),
      ]);
    });

    test('plugin edits dispatch bus intents addressed to this stage', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(),
      );
      const address = FxAddress(stage: FxStage.master);
      const ref = PluginRef(format: PluginFormat.vst3, id: 'a', version: 1);

      masterScope()
        ..insertPlugin(ref)
        ..setPluginParam(0, 7, 0.5)
        ..relinkPlugin(0, ref);

      final events = verify(() => bloc.add(captureAny())).captured;
      expect(events, [
        const LooperBusPluginInserted(address, ref),
        const LooperBusPluginParamChanged(address, 0, 7, 0.5),
        const LooperBusPluginRelinked(address, 0, ref),
      ]);
    });

    test('power controls dispatch the stage-matched enable events', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            Track(effects: [BuiltInEffect(type: TrackEffectType.drive)]),
          ],
        ),
      );

      trackScope(0)
        ..setEffectEnabled(0, enabled: false)
        ..setChainEnabled(enabled: false);
      masterScope()
        ..setEffectEnabled(1, enabled: true)
        ..setChainEnabled(enabled: true);

      final events = verify(() => bloc.add(captureAny())).captured;
      expect(
        events[0],
        const LooperTrackEffectEnabledToggled(0, 0, enabled: false),
      );
      expect(
        events[1],
        const LooperTrackChainEnabledToggled(0, enabled: false),
      );
      expect(
        events[2],
        const LooperMasterEffectEnabledToggled(1, enabled: true),
      );
      expect(events[3], const LooperMasterChainEnabledToggled(enabled: true));
    });

    test('a bus stage inherits nothing and never re-syncs', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(tracks: const [Track()]),
      );
      final scope = trackScope(0);

      expect(scope.inheritedFrom, isEmpty);
      expect(scope.canResyncFromInput, isFalse);
      expect(scope.overdubMismatch, isFalse);
    });

    test('a bus-stage plugin has no native editor or live readout', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(tracks: const [Track()]),
      );
      // No slot ABI at the bus stages yet: the entry is preserved and marked
      // unsupported by the domain, so there is nothing to open or read back.
      final scope = trackScope(0)..openPluginEditor(0);
      expect(scope.formatPluginValue(0, 1, 0.5), isNull);
      verifyNever(() => bloc.add(any()));
    });
  });

  group('loop-stage inheritance', () {
    test('reads provenance and the overdub mismatch off the lane', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            const Track(
              state: TrackState.overdubbing,
              lanes: [
                Lane(inheritedFrom: [1], inputChainDiverges: true),
              ],
            ),
          ],
        ),
      );
      final scope = LaneFxScope(
        looper: bloc,
        repository: repository,
        track: 0,
        lane: 0,
      );

      expect(scope.inheritedFrom, [1]);
      // A7: overdubbing onto a chain that has drifted from its input.
      expect(scope.overdubMismatch, isTrue);
    });

    test('a diverged lane that is NOT overdubbing raises no hint', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: [
            const Track(
              state: TrackState.playing,
              lanes: [Lane(inputChainDiverges: true)],
            ),
          ],
        ),
      );
      final scope = LaneFxScope(
        looper: bloc,
        repository: repository,
        track: 0,
        lane: 0,
      );

      expect(scope.overdubMismatch, isFalse);
    });

    test('re-sync is offered only with an audible input chain to copy', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: const [
            Track(lanes: [Lane()]),
          ],
        ),
      );
      final scope = LaneFxScope(
        looper: bloc,
        repository: repository,
        track: 0,
        lane: 0,
      );
      expect(scope.canResyncFromInput, isFalse);

      repository.setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      expect(scope.canResyncFromInput, isTrue);

      // A chain-disabled input sounds dry, so there is nothing to inherit.
      repository.setMonitorChainEnabled(input: 0, enabled: false);
      expect(scope.canResyncFromInput, isFalse);
    });

    test('re-sync dispatches the explicit, user-initiated re-copy', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: const [
            Track(lanes: [Lane()]),
          ],
        ),
      );
      LaneFxScope(
        looper: bloc,
        repository: repository,
        track: 0,
        lane: 0,
      ).resyncFromInput();

      verify(
        () => bloc.add(const LooperLaneChainResyncedFromInput(0, 0)),
      ).called(1);
    });

    test('lane power controls dispatch the loop-stage enable events', () {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: _state(
          tracks: const [
            Track(lanes: [Lane()]),
          ],
        ),
      );
      LaneFxScope(
          looper: bloc,
          repository: repository,
          track: 0,
          lane: 0,
        )
        ..setEffectEnabled(2, enabled: false)
        ..setChainEnabled(enabled: false);

      verify(
        () => bloc.add(
          const LooperLaneEffectEnabledToggled(0, 0, 2, enabled: false),
        ),
      ).called(1);
      verify(
        () => bloc.add(
          const LooperLaneChainEnabledToggled(0, 0, enabled: false),
        ),
      ).called(1);
    });
  });
}
