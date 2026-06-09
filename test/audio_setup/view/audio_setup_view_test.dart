import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

void main() {
  late AudioSetupCubit cubit;

  setUp(() => cubit = _MockAudioSetupCubit());

  void seed(AudioSetupState state) {
    when(() => cubit.state).thenReturn(state);
    whenListen(
      cubit,
      const Stream<AudioSetupState>.empty(),
      initialState: state,
    );
  }

  Future<void> pumpView(WidgetTester tester) {
    return tester.pumpApp(
      BlocProvider<AudioSetupCubit>.value(
        value: cubit,
        child: const AudioSetupView(),
      ),
    );
  }

  testWidgets('starts on the engine step with selectable sample rates', (
    tester,
  ) async {
    seed(const AudioSetupState());
    await pumpView(tester);

    expect(
      find.byKey(const Key('audioSetup_sampleRate_48000')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('audioSetup_next_button')), findsOneWidget);
    // Start and measure are not reachable yet (later step / running only).
    expect(find.byKey(const Key('audioSetup_startStop_button')), findsNothing);
    expect(
      find.byKey(const Key('audioSetup_measureLatency_button')),
      findsNothing,
    );
  });

  testWidgets('selecting a sample rate forwards to the cubit', (tester) async {
    seed(const AudioSetupState());
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('audioSetup_sampleRate_96000')));
    verify(() => cubit.setSampleRate(96000)).called(1);
  });

  testWidgets('stepping to the end and starting calls cubit.start', (
    tester,
  ) async {
    seed(const AudioSetupState());
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('audioSetup_next_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('audioSetup_next_button')));
    await tester.pumpAndSettle();

    expect(find.text('Start engine'), findsOneWidget);
    await tester.tap(find.byKey(const Key('audioSetup_startStop_button')));
    await tester.pump();

    verify(cubit.start).called(1);
  });

  testWidgets('running state shows the live panel with stop and measure', (
    tester,
  ) async {
    seed(
      const AudioSetupState(
        status: AudioSetupStatus.running,
        engineStatus: EngineStatus(deviceName: 'Scarlett', isConnected: true),
      ),
    );
    await pumpView(tester);

    expect(find.text('Scarlett'), findsOneWidget);
    expect(find.text('Stop engine'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('audioSetup_measureLatency_button')),
    );
    verify(cubit.measureLatency).called(1);

    await tester.tap(find.byKey(const Key('audioSetup_startStop_button')));
    verify(cubit.stop).called(1);
  });

  testWidgets('error state shows the error banner', (tester) async {
    seed(
      const AudioSetupState(
        status: AudioSetupStatus.error,
        errorMessage: 'Failed to start audio: device',
      ),
    );
    await pumpView(tester);

    expect(find.byKey(const Key('audioSetup_error_text')), findsOneWidget);
  });
}
