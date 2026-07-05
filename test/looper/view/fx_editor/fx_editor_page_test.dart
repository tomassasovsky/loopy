import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/fx_editor/fx_editor_page.dart';
import 'package:loopy/looper/view/fx_editor/fx_scope.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

LooperState _state({List<Track> tracks = const []}) => LooperState(
  tracks: tracks,
  status: const EngineStatus(
    inputChannels: 2,
    outputChannels: 2,
    isConnected: true,
  ),
);

Track _trackWith(List<TrackEffect> effects) =>
    Track(lanes: [Lane(effects: effects)]);

void main() {
  late LooperBloc bloc;
  late MonitorCubit monitor;
  late LooperRepository repository;

  setUp(() {
    bloc = _MockLooperBloc();
    repository = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
    monitor = MonitorCubit(
      repository: repository,
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
  });

  tearDown(() async {
    await monitor.close();
    await repository.dispose();
  });

  Future<void> pumpView(WidgetTester tester, FxScope scope) => tester.pumpApp(
    RepositoryProvider<LooperRepository>.value(
      value: repository,
      child: MultiBlocProvider(
        providers: [
          BlocProvider<LooperBloc>.value(value: bloc),
          BlocProvider<MonitorCubit>.value(value: monitor),
        ],
        child: FxEditorView(scope: scope),
      ),
    ),
  );

  LaneFxScope laneScope() =>
      LaneFxScope(looper: bloc, repository: repository, track: 0, lane: 0);

  testWidgets('a lane scope shows its label and consequence', (tester) async {
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: _state(tracks: [_trackWith(const [])]),
    );
    await pumpView(tester, laneScope());

    expect(find.text('Lane 1'), findsOneWidget);
    expect(find.text('shapes playback, non-destructive'), findsOneWidget);
  });

  testWidgets('an input scope shows its title and consequence', (tester) async {
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: _state(),
    );
    await pumpView(
      tester,
      InputFxScope(
        monitor: monitor,
        looper: bloc,
        repository: repository,
        input: 0,
      ),
    );

    expect(find.text('Input 1'), findsOneWidget);
    expect(find.text('prints into new takes'), findsOneWidget);
  });

  testWidgets('opening selects the first block', (tester) async {
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: _state(
        tracks: [
          _trackWith([
            BuiltInEffect(type: TrackEffectType.drive),
            BuiltInEffect(type: TrackEffectType.reverb),
          ]),
        ],
      ),
    );
    await pumpView(tester, laneScope());

    // The first block is auto-selected, so its params fill the inspector.
    expect(find.byKey(const Key('fxInspector_param_0')), findsOneWidget);
    final block0 = tester.getSemantics(
      find.byKey(const Key('fxChain_block_0')),
    );
    expect(block0, isSemantics(isSelected: true));
  });

  testWidgets('an empty chain reads as the clean-take hint', (tester) async {
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: _state(tracks: [_trackWith(const [])]),
    );
    await pumpView(tester, laneScope());

    expect(find.byKey(const Key('fxInspector_empty')), findsOneWidget);
    expect(
      find.textContaining('records its input clean'),
      findsOneWidget,
    );
  });

  testWidgets('empty-states when the lane is removed while open', (
    tester,
  ) async {
    final controller = StreamController<LooperState>();
    addTearDown(controller.close);
    whenListen(
      bloc,
      controller.stream,
      initialState: _state(tracks: [_trackWith(const [])]),
    );
    await pumpView(tester, laneScope());
    expect(find.byKey(const Key('fxEditor_gone')), findsNothing);

    // The track (and its lane) is removed out from under the open editor.
    controller.add(_state());
    await tester.pump();

    expect(find.byKey(const Key('fxEditor_gone')), findsOneWidget);
  });

  testWidgets('back navigation closes the pushed editor', (tester) async {
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: _state(tracks: [_trackWith(const [])]),
    );
    await tester.pumpApp(
      RepositoryProvider<LooperRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<MonitorCubit>.value(value: monitor),
          ],
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showFxEditorPage(context, scope: laneScope()),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fx_editor_page')), findsOneWidget);

    await tester.tap(find.byKey(const Key('fxEditor_back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fx_editor_page')), findsNothing);
  });
}
