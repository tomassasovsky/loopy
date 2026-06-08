import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late LooperBloc bloc;

  setUp(() => bloc = _MockLooperBloc());

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pumpView(WidgetTester tester) {
    return tester.pumpApp(
      RepositoryProvider<LooperRepository>.value(
        value: _MockLooperRepository(),
        child: BlocProvider<LooperBloc>.value(
          value: bloc,
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
}
