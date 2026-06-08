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

  testWidgets('renders device options; measure disabled while stopped', (
    tester,
  ) async {
    seed(const AudioSetupState());
    await pumpView(tester);

    expect(
      find.byKey(const Key('audioSetup_sampleRate_dropdown')),
      findsOneWidget,
    );
    expect(find.text('Start engine'), findsOneWidget);
    final measureButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('audioSetup_measureLatency_button')),
    );
    expect(measureButton.enabled, isFalse);
  });

  testWidgets('tapping start calls cubit.start', (tester) async {
    seed(const AudioSetupState());
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('audioSetup_startStop_button')));
    await tester.pump();

    verify(cubit.start).called(1);
  });

  testWidgets('running state shows stop and enables latency measurement', (
    tester,
  ) async {
    seed(
      const AudioSetupState(
        status: AudioSetupStatus.running,
        engineStatus: EngineStatus(deviceName: 'Scarlett', isConnected: true),
      ),
    );
    await pumpView(tester);

    expect(find.text('Stop engine'), findsOneWidget);
    expect(find.text('Scarlett'), findsOneWidget);
    final measureButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('audioSetup_measureLatency_button')),
    );
    expect(measureButton.enabled, isTrue);
  });

  testWidgets('error state shows the error text', (tester) async {
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
