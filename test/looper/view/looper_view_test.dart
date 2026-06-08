import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/session/session.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

void main() {
  late LooperBloc bloc;
  late SessionCubit sessionCubit;

  setUp(() {
    bloc = _MockLooperBloc();
    sessionCubit = _MockSessionCubit();
    whenListen(
      sessionCubit,
      const Stream<SessionState>.empty(),
      initialState: const SessionState(),
    );
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pumpView(WidgetTester tester) {
    return tester.pumpApp(
      RepositoryProvider<LooperRepository>.value(
        value: _MockLooperRepository(),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<SessionCubit>.value(value: sessionCubit),
          ],
          child: const LooperView(),
        ),
      ),
    );
  }

  testWidgets('renders a strip per track and the stopped banner', (
    tester,
  ) async {
    seed(
      const LooperState(
        tracks: [Track(), Track(channel: 1)],
      ),
    );
    await pumpView(tester);

    expect(find.byKey(const Key('looper_track_0')), findsOneWidget);
    expect(find.byKey(const Key('looper_track_1')), findsOneWidget);
    expect(
      find.byKey(const Key('looper_engineStopped_banner')),
      findsOneWidget,
    );
  });

  testWidgets('tapping record on a track dispatches with its channel', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('looper_record_button_1')));
    await tester.pump();

    verify(() => bloc.add(const LooperRecordPressed(1))).called(1);
  });

  testWidgets('reflects a playing track and enables stop', (tester) async {
    seed(
      const LooperState(
        transport: TransportState(isRunning: true, masterLengthFrames: 48000),
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 48000),
        ],
      ),
    );
    await pumpView(tester);

    expect(find.widgetWithText(Chip, 'playing'), findsOneWidget);
    expect(
      find.byKey(const Key('looper_engineStopped_banner')),
      findsNothing,
    );

    final stopButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('looper_stop_button_0')),
    );
    expect(stopButton.enabled, isTrue);

    await tester.tap(find.byKey(const Key('looper_stop_button_0')));
    await tester.pump();
    verify(() => bloc.add(const LooperStopPressed(0))).called(1);
  });

  testWidgets('play all dispatches LooperPlayAllPressed', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('looper_playAll_button')));
    await tester.pump();

    verify(() => bloc.add(const LooperPlayAllPressed())).called(1);
  });

  testWidgets('tempo bar shows BPM and dispatches tap/metronome', (
    tester,
  ) async {
    seed(
      const LooperState(
        transport: TransportState(isRunning: true, tempoBpm: 128),
        tracks: [Track()],
      ),
    );
    await pumpView(tester);

    expect(find.text('128 BPM'), findsOneWidget);

    await tester.tap(find.byKey(const Key('looper_tap_button')));
    await tester.pump();
    verify(() => bloc.add(const LooperTapTempo())).called(1);

    await tester.tap(find.byKey(const Key('looper_metronome_button')));
    await tester.pump();
    verify(() => bloc.add(const LooperMetronomeToggled())).called(1);

    await tester.tap(find.byKey(const Key('looper_countIn_button')));
    await tester.pump();
    verify(() => bloc.add(const LooperCountInToggled())).called(1);

    await tester.tap(find.byKey(const Key('looper_syncTempo_button')));
    await tester.pump();
    verify(() => bloc.add(const LooperSyncTempoToggled())).called(1);
  });

  testWidgets('tempo bar shows the synced bar count when a loop exists', (
    tester,
  ) async {
    seed(
      const LooperState(
        transport: TransportState(
          isRunning: true,
          masterLengthFrames: 96000,
          loopBars: 2,
        ),
        tracks: [Track()],
      ),
    );
    await pumpView(tester);

    expect(find.byKey(const Key('looper_bars_text')), findsOneWidget);
    expect(find.text('2 bars'), findsOneWidget);
  });

  testWidgets('quantize menu dispatches the selected mode', (tester) async {
    seed(
      const LooperState(
        transport: TransportState(isRunning: true),
        tracks: [Track()],
      ),
    );
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('looper_quantize_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quantize: beat'));
    await tester.pumpAndSettle();

    verify(
      () => bloc.add(const LooperQuantizeChanged(QuantizeMode.beat)),
    ).called(1);
  });

  testWidgets('an armed track shows the armed chip', (tester) async {
    seed(
      const LooperState(
        transport: TransportState(isRunning: true, armedChannel: 0),
        tracks: [Track(state: TrackState.playing, armed: true)],
      ),
    );
    await pumpView(tester);

    expect(find.byKey(const Key('looper_armed_chip_0')), findsOneWidget);
    expect(find.text('armed'), findsOneWidget);
  });

  testWidgets('a multi-loop track shows its multiple chip', (tester) async {
    seed(
      const LooperState(
        transport: TransportState(isRunning: true, masterLengthFrames: 48000),
        tracks: [
          Track(
            state: TrackState.playing,
            lengthFrames: 96000,
            multiple: 2,
          ),
        ],
      ),
    );
    await pumpView(tester);

    expect(find.byKey(const Key('looper_multiple_chip_0')), findsOneWidget);
    expect(find.text('×2'), findsOneWidget);
  });

  testWidgets('session menu saves via the cubit', (tester) async {
    when(() => sessionCubit.saveSession()).thenAnswer((_) async {});
    seed(const LooperState(tracks: [Track()]));
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('looper_session_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save session'));
    await tester.pumpAndSettle();

    verify(() => sessionCubit.saveSession()).called(1);
  });

  testWidgets('undo is disabled without an undo layer', (tester) async {
    seed(
      const LooperState(tracks: [Track(state: TrackState.playing)]),
    );
    await pumpView(tester);

    final undoButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('looper_undo_button_0')),
    );
    expect(undoButton.enabled, isFalse);
  });

  testWidgets('redo enables and dispatches when a track has redo history', (
    tester,
  ) async {
    seed(
      const LooperState(
        tracks: [Track(state: TrackState.playing, redoDepth: 1)],
      ),
    );
    await pumpView(tester);

    final redoButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('looper_redo_button_0')),
    );
    expect(redoButton.enabled, isTrue);

    await tester.tap(find.byKey(const Key('looper_redo_button_0')));
    await tester.pump();
    verify(() => bloc.add(const LooperRedoPressed(0))).called(1);
  });
}
