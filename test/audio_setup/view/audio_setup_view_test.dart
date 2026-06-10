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

  testWidgets('the input step forwards the monitor toggle', (tester) async {
    seed(const AudioSetupState());
    await pumpView(tester);

    await tester.tap(find.byKey(const Key('audioSetup_next_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('audioSetup_monitor_switch')));
    verify(() => cubit.setMonitorInput(monitorInput: false)).called(1);

    // Merge-to-mono was removed: its toggle must no longer be rendered.
    expect(
      find.byKey(const Key('audioSetup_mergeToMono_switch')),
      findsNothing,
    );
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

  testWidgets('the engine step lists output devices and System default', (
    tester,
  ) async {
    seed(
      const AudioSetupState(
        devices: [
          AudioDevice(
            id: 'out-1',
            name: 'Scarlett 2i2',
            isDefault: true,
            isInput: false,
          ),
        ],
      ),
    );
    await pumpView(tester);

    final picker = find.byKey(const Key('audioSetup_playbackDevice_picker'));
    expect(picker, findsOneWidget);

    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.text('System default'), findsWidgets);
    expect(find.text('Scarlett 2i2'), findsWidgets);
  });

  testWidgets('selecting an output device forwards to the cubit', (
    tester,
  ) async {
    seed(
      const AudioSetupState(
        devices: [
          AudioDevice(
            id: 'out-1',
            name: 'Scarlett 2i2',
            isDefault: true,
            isInput: false,
          ),
        ],
      ),
    );
    await pumpView(tester);

    await tester.tap(
      find.byKey(const Key('audioSetup_playbackDevice_picker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scarlett 2i2').last);
    await tester.pumpAndSettle();

    verify(() => cubit.setPlaybackDevice('out-1')).called(1);
  });

  testWidgets('the input step lists capture devices and forwards selection', (
    tester,
  ) async {
    seed(
      const AudioSetupState(
        devices: [
          AudioDevice(
            id: 'in-1',
            name: 'Built-in Mic',
            isDefault: true,
            isInput: true,
          ),
        ],
      ),
    );
    await pumpView(tester);

    // Advance the wizard to the Input step.
    await tester.tap(find.byKey(const Key('audioSetup_next_button')));
    await tester.pumpAndSettle();

    final picker = find.byKey(const Key('audioSetup_captureDevice_picker'));
    expect(picker, findsOneWidget);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.text('Built-in Mic'), findsWidgets);
    await tester.tap(find.text('Built-in Mic').last);
    await tester.pumpAndSettle();

    verify(() => cubit.setCaptureDevice('in-1')).called(1);
  });
}
