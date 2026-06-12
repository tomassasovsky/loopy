import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late AudioSetupCubit cubit;
  late MonitorCubit monitor;
  late QuantizeCubit quantize;
  late RecordOptionsCubit recordOptions;

  setUp(() {
    cubit = _MockAudioSetupCubit();
    final repository = _MockLooperRepository();
    when(
      () => repository.setMonitorInput(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
        outputMask: any(named: 'outputMask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorDry(
        input: any(named: 'input'),
        dryOutputMask: any(named: 'dryOutputMask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setAutoRecord(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    monitor = MonitorCubit(repository: repository, settings: settings);
    quantize = QuantizeCubit(repository: repository, settings: settings);
    recordOptions = RecordOptionsCubit(
      repository: repository,
      settings: settings,
    );
  });

  void seed(AudioSetupState state) {
    when(() => cubit.state).thenReturn(state);
    whenListen(
      cubit,
      const Stream<AudioSetupState>.empty(),
      initialState: state,
    );
  }

  Future<void> pumpSection(WidgetTester tester) => tester.pumpApp(
    MultiBlocProvider(
      providers: [
        BlocProvider<AudioSetupCubit>.value(value: cubit),
        BlocProvider<MonitorCubit>.value(value: monitor),
        BlocProvider<QuantizeCubit>.value(value: quantize),
        BlocProvider<RecordOptionsCubit>.value(value: recordOptions),
      ],
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
    // Sample-rate and buffer selectors are editable in settings.
    expect(
      find.byKey(const Key('audioSettings_sampleRate_48000')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('audioSettings_bufferSize_128')),
      findsOneWidget,
    );
    // Live status reflects the running engine + restored/measured latency.
    // "48000 Hz" appears twice: the sample-rate selector option and the status.
    expect(find.text('48000 Hz'), findsNWidgets(2));
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

    final button = find.byKey(const Key('audioSettings_measure_button'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    verify(cubit.measureLatency).called(1);
  });

  testWidgets('toggling monitor input forwards to the cubit', (tester) async {
    seed(runningState); // monitorInput defaults to true
    await pumpSection(tester);

    final toggle = find.byKey(const Key('audioSettings_monitor_switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    verify(() => cubit.setMonitorInput(monitorInput: false)).called(1);
  });

  testWidgets('opens the input-monitoring graph as a full page', (
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
          inputChannels: 2,
          outputChannels: 2,
        ),
      ),
    );
    await pumpSection(tester);

    final open = find.byKey(const Key('audioSettings_openMonitorGraph'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();

    // The full-page routing graph opens (replacing the old chip tiles).
    expect(find.byKey(const Key('monitorRouting_page')), findsOneWidget);
    expect(find.byKey(const Key('monitorGraph_in_0')), findsOneWidget);
    expect(find.byKey(const Key('monitorGraph_out_0')), findsOneWidget);
  });

  testWidgets('toggling quantize recording forwards to the quantize cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);
    expect(quantize.state, isFalse);

    final toggle = find.byKey(const Key('audioSettings_quantize_switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(quantize.state, isTrue);
  });

  testWidgets('the rec/dub and sound-activated toggles forward to the cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);
    expect(recordOptions.state.recDub, isFalse);
    expect(recordOptions.state.autoRecord, isFalse);

    final recDub = find.byKey(const Key('audioSettings_recDub_switch'));
    await tester.ensureVisible(recDub);
    await tester.tap(recDub);
    await tester.pumpAndSettle();
    expect(recordOptions.state.recDub, isTrue);

    final autoRecord = find.byKey(
      const Key('audioSettings_autoRecord_switch'),
    );
    await tester.ensureVisible(autoRecord);
    await tester.tap(autoRecord);
    await tester.pumpAndSettle();
    expect(recordOptions.state.autoRecord, isTrue);
  });

  testWidgets('choosing a default loop length forwards to the cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);
    expect(recordOptions.state.defaultMultiple, 0);

    final x2 = find.byKey(const Key('audioSettings_defaultMultiple_2'));
    await tester.ensureVisible(x2);
    await tester.tap(x2);
    await tester.pumpAndSettle();

    expect(recordOptions.state.defaultMultiple, 2);
  });

  testWidgets('choosing a max loop length forwards to the cubit', (
    tester,
  ) async {
    seed(runningState); // maxLoopMinutes defaults to 0 (engine default)
    await pumpSection(tester);

    final option = find.byKey(const Key('audioSettings_maxLoop_5'));
    await tester.ensureVisible(option);
    await tester.tap(option);
    verify(() => cubit.setMaxLoopMinutes(5)).called(1);
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
