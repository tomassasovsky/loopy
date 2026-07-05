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

LooperState _state({List<Track> tracks = const [], int inputChannels = 2}) =>
    LooperState(
      tracks: tracks,
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
}
