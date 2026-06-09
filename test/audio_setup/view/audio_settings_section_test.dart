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

  Future<void> pumpSection(WidgetTester tester) => tester.pumpApp(
    BlocProvider<AudioSetupCubit>.value(
      value: cubit,
      child: const Material(
        child: SingleChildScrollView(child: AudioSettingsSection()),
      ),
    ),
  );

  const runningState = AudioSetupState(
    status: AudioSetupStatus.running,
    devices: [
      AudioDevice(
        id: 'out-1',
        name: 'Scarlett 4i4',
        isDefault: true,
        isInput: false,
      ),
      AudioDevice(
        id: 'in-1',
        name: 'Scarlett Input 1',
        isDefault: true,
        isInput: true,
      ),
    ],
    engineStatus: EngineStatus(
      deviceName: 'Scarlett 4i4',
      sampleRate: 48000,
      bufferFrames: 128,
      isConnected: true,
      latencyState: LatencyState.done,
      measuredLatencyMs: 9.5,
      recordOffsetFrames: 456,
    ),
  );

  testWidgets('renders device pickers and the live status', (tester) async {
    seed(runningState);
    await pumpSection(tester);

    expect(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('audioSettings_captureDevice_picker')),
      findsOneWidget,
    );
    // Live status reflects the running engine + restored/measured latency.
    expect(find.text('48000 Hz'), findsOneWidget);
    expect(find.text('128 frames'), findsOneWidget);
    expect(find.text('9.50 ms'), findsOneWidget);
    expect(find.text('456 frames'), findsOneWidget);
  });

  testWidgets('selecting a playback device forwards to the cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);

    await tester.tap(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scarlett 4i4').last);
    await tester.pumpAndSettle();

    verify(() => cubit.setPlaybackDevice('out-1')).called(1);
  });

  testWidgets('selecting a capture device forwards to the cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);

    await tester.tap(
      find.byKey(const Key('audioSettings_captureDevice_picker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scarlett Input 1').last);
    await tester.pumpAndSettle();

    verify(() => cubit.setCaptureDevice('in-1')).called(1);
  });

  testWidgets('the measure button triggers a measurement', (tester) async {
    seed(runningState);
    await pumpSection(tester);

    await tester.tap(find.byKey(const Key('audioSettings_measure_button')));
    verify(cubit.measureLatency).called(1);
  });

  testWidgets('shows a measuring label while a measurement is in flight', (
    tester,
  ) async {
    seed(
      const AudioSetupState(
        status: AudioSetupStatus.running,
        engineStatus: EngineStatus(
          deviceName: 'Scarlett 4i4',
          sampleRate: 48000,
          bufferFrames: 128,
          isConnected: true,
          latencyState: LatencyState.measuring,
        ),
      ),
    );
    await pumpSection(tester);

    // Both the status row and the action button reflect the measuring state.
    expect(find.text('Measuring…'), findsWidgets);
  });

  testWidgets('shows the not-running status before the engine starts', (
    tester,
  ) async {
    seed(const AudioSetupState()); // stopped, empty engine status
    await pumpSection(tester);

    expect(find.text('Not running'), findsOneWidget);
    expect(find.text('Not measured'), findsOneWidget);
  });
}
