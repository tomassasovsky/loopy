import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockPedalCubit extends MockCubit<PedalState> implements PedalCubit {}

void main() {
  testWidgets(
    'mirrors the pedal cursor onto the app selection and reveals its bank',
    (tester) async {
      final pedal = _MockPedalCubit();
      final states = StreamController<PedalState>.broadcast();
      when(() => pedal.state).thenReturn(const PedalState());
      whenListen(pedal, states.stream, initialState: const PedalState());
      final tracks = TracksCubit(
        settings: SettingsRepository(store: FakeKeyValueStore()),
      );
      addTearDown(states.close);
      addTearDown(tracks.close);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<PedalCubit>.value(value: pedal),
            BlocProvider<TracksCubit>.value(value: tracks),
          ],
          child: const PedalCursorBridge(child: SizedBox()),
        ),
      );

      // The pedal moves its cursor to channel 5 (in bank B).
      states.add(const PedalState(selectedTrack: 5, activeBank: 1));
      await tester.pump();

      // The app's selection follows, and select() also revealed bank B.
      expect(tracks.state.selectedChannel, 5);
      expect(tracks.state.activeBank, 1);
    },
  );

  testWidgets(
    'mirrors the on-screen selection back onto the pedal cursor, so pedal '
    'UNDO/Rec-Play/STOP act on the track the user is looking at',
    (tester) async {
      final pedal = _MockPedalCubit();
      final states = StreamController<PedalState>.broadcast();
      when(() => pedal.state).thenReturn(const PedalState());
      whenListen(pedal, states.stream, initialState: const PedalState());
      final tracks = TracksCubit(
        settings: SettingsRepository(store: FakeKeyValueStore()),
      );
      addTearDown(states.close);
      addTearDown(tracks.close);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<PedalCubit>.value(value: pedal),
            BlocProvider<TracksCubit>.value(value: tracks),
          ],
          child: const PedalCursorBridge(child: SizedBox()),
        ),
      );

      // The user clicks track 6 on screen (digit key / tile tap).
      tracks.select(6);
      await tester.pump();

      verify(() => pedal.selectTrack(6)).called(1);
    },
  );
}
