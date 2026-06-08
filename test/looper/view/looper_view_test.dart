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

  testWidgets('shows the empty track state and the stopped banner', (
    tester,
  ) async {
    seed(const LooperState());
    await pumpView(tester);

    expect(find.widgetWithText(Chip, 'empty'), findsOneWidget);
    expect(
      find.byKey(const Key('looper_engineStopped_banner')),
      findsOneWidget,
    );
  });

  testWidgets('tapping record dispatches LooperRecordPressed', (tester) async {
    seed(const LooperState());
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('looper_record_button')));
    await tester.pump();

    verify(() => bloc.add(const LooperRecordPressed())).called(1);
  });

  testWidgets('reflects a playing state, hides the banner, enables stop', (
    tester,
  ) async {
    seed(
      const LooperState(
        transport: TransportState(isRunning: true, masterLengthFrames: 48000),
        track: Track(state: TrackState.playing, lengthFrames: 48000),
      ),
    );
    await pumpView(tester);

    expect(find.widgetWithText(Chip, 'playing'), findsOneWidget);
    expect(
      find.byKey(const Key('looper_engineStopped_banner')),
      findsNothing,
    );

    final stopButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('looper_stop_button')),
    );
    expect(stopButton.enabled, isTrue);

    await tester.tap(find.byKey(const Key('looper_stop_button')));
    await tester.pump();
    verify(() => bloc.add(const LooperStopPressed())).called(1);
  });

  testWidgets('undo is disabled without an undo layer', (tester) async {
    seed(const LooperState(track: Track(state: TrackState.playing)));
    await pumpView(tester);

    final undoButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('looper_undo_button')),
    );
    expect(undoButton.enabled, isFalse);
  });
}
