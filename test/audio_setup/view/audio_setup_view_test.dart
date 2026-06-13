import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
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

  group('exclusive mode (Windows-only toggle)', () {
    // Safety net for a throwing test; passing tests also reset inline because
    // the foundation-vars invariant is checked before tearDown runs.
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    testWidgets('engine step shows the toggle and forwards taps on Windows', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      seed(const AudioSetupState());
      await pumpView(tester);

      final toggle = find.byKey(const Key('audioSetup_exclusive_switch'));
      expect(toggle, findsOneWidget);
      await tester.ensureVisible(toggle); // it sits below the fold
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      verify(() => cubit.setExclusive(exclusive: true)).called(1);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('toggling the exclusive switch off forwards false', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      seed(const AudioSetupState(exclusive: true));
      await pumpView(tester);

      final toggle = find.byKey(const Key('audioSetup_exclusive_switch'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      verify(() => cubit.setExclusive(exclusive: false)).called(1);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the exclusive toggle is hidden off Windows', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      seed(const AudioSetupState());
      await pumpView(tester);

      expect(
        find.byKey(const Key('audioSetup_exclusive_switch')),
        findsNothing,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('running panel surfaces the shared-fallback note on mismatch', (
      tester,
    ) async {
      // Exclusive requested but the device opened shared => show the note.
      seed(
        const AudioSetupState(
          status: AudioSetupStatus.running,
          exclusive: true,
          engineStatus: EngineStatus(deviceName: 'Scarlett', isConnected: true),
        ),
      );
      await pumpView(tester);

      expect(
        find.byKey(const Key('audioSetup_exclusiveFallback_note')),
        findsOneWidget,
      );
    });

    testWidgets('no fallback note when exclusive actually engaged', (
      tester,
    ) async {
      seed(
        const AudioSetupState(
          status: AudioSetupStatus.running,
          exclusive: true,
          engineStatus: EngineStatus(
            deviceName: 'Scarlett',
            isConnected: true,
            exclusiveActive: true,
          ),
        ),
      );
      await pumpView(tester);

      expect(
        find.byKey(const Key('audioSetup_exclusiveFallback_note')),
        findsNothing,
      );
    });
  });

  testWidgets('error state shows the error banner', (tester) async {
    seed(
      const AudioSetupState(
        status: AudioSetupStatus.error,
        error: AudioSetupError.startAudioFailed,
        errorDetail: 'device',
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
    // "System default" names the resolved default device.
    expect(find.text('System default (Scarlett 2i2)'), findsWidgets);
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

  group('asio backend selector', () {
    const asioDriver = AudioDevice(
      id: 'Focusrite USB ASIO',
      name: 'Focusrite USB ASIO',
      isDefault: false,
      isInput: false,
      inputChannels: 18,
      outputChannels: 20,
    );

    testWidgets('shows the selector and forwards a backend choice when drivers '
        'are present', (tester) async {
      seed(const AudioSetupState(asioDrivers: [asioDriver]));
      await pumpView(tester);

      expect(find.byKey(const Key('audioSetup_backend_asio')), findsOneWidget);
      await tester.tap(find.byKey(const Key('audioSetup_backend_asio')));
      verify(() => cubit.setBackend(AudioBackend.asio)).called(1);
    });

    testWidgets('hides the selector when no drivers enumerated', (
      tester,
    ) async {
      seed(const AudioSetupState());
      await pumpView(tester);

      expect(find.byKey(const Key('audioSetup_backend_asio')), findsNothing);
      expect(find.byKey(const Key('audioSetup_backend_wasapi')), findsNothing);
    });

    testWidgets('under ASIO the driver picker replaces the output picker', (
      tester,
    ) async {
      seed(
        const AudioSetupState(
          backend: AudioBackend.asio,
          asioDriver: 'Focusrite USB ASIO',
          asioDrivers: [asioDriver],
        ),
      );
      await pumpView(tester);

      expect(
        find.byKey(const Key('audioSetup_asioDriver_picker')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audioSetup_playbackDevice_picker')),
        findsNothing,
      );
    });

    testWidgets('selecting an ASIO driver forwards to the cubit', (
      tester,
    ) async {
      seed(
        const AudioSetupState(
          backend: AudioBackend.asio,
          asioDrivers: [asioDriver],
        ),
      );
      await pumpView(tester);

      await tester.tap(find.byKey(const Key('audioSetup_asioDriver_picker')));
      await tester.pumpAndSettle();
      // The driver label includes its probed channel counts.
      await tester.tap(find.textContaining('18 in / 20 out').last);
      await tester.pumpAndSettle();

      verify(() => cubit.setAsioDriver('Focusrite USB ASIO')).called(1);
    });

    testWidgets('under ASIO the input step hides the capture picker', (
      tester,
    ) async {
      seed(
        const AudioSetupState(
          backend: AudioBackend.asio,
          asioDriver: 'Focusrite USB ASIO',
          asioDrivers: [asioDriver],
        ),
      );
      await pumpView(tester);

      await tester.tap(find.byKey(const Key('audioSetup_next_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('audioSetup_asioInput_note')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audioSetup_captureDevice_picker')),
        findsNothing,
      );
    });

    testWidgets('under ASIO the buffer chips come from the driver set', (
      tester,
    ) async {
      // A driver locked to a single buffer size: only that chip is offered, not
      // the generic 64/128/256/512 list.
      seed(
        const AudioSetupState(
          backend: AudioBackend.asio,
          asioDriver: 'Locked ASIO',
          bufferFrames: 256,
          asioDrivers: [
            AudioDevice(
              id: 'Locked ASIO',
              name: 'Locked ASIO',
              isDefault: false,
              isInput: false,
              inputChannels: 2,
              outputChannels: 2,
              bufferSizes: [256],
              sampleRates: [48000],
            ),
          ],
        ),
      );
      await pumpView(tester);

      expect(
        find.byKey(const Key('audioSetup_bufferSize_256')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audioSetup_bufferSize_512')),
        findsNothing,
      );
    });

    testWidgets(
      'the running panel surfaces the ASIO fallback note on mismatch',
      (tester) async {
        // ASIO requested but the device opened on WASAPI => show the note, and
        // suppress the (dormant) exclusive-shared fallback under ASIO.
        seed(
          const AudioSetupState(
            status: AudioSetupStatus.running,
            backend: AudioBackend.asio,
            asioDriver: 'Focusrite USB ASIO',
            exclusive: true,
            engineStatus: EngineStatus(
              deviceName: 'Realtek',
              isConnected: true,
            ),
          ),
        );
        await pumpView(tester);

        expect(
          find.byKey(const Key('audioSetup_asioFallback_note')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('audioSetup_exclusiveFallback_note')),
          findsNothing,
        );
      },
    );

    testWidgets('no ASIO fallback note when ASIO actually engaged', (
      tester,
    ) async {
      seed(
        const AudioSetupState(
          status: AudioSetupStatus.running,
          backend: AudioBackend.asio,
          asioDriver: 'Focusrite USB ASIO',
          engineStatus: EngineStatus(
            deviceName: 'Focusrite USB ASIO',
            isConnected: true,
            activeBackend: AudioBackend.asio,
          ),
        ),
      );
      await pumpView(tester);

      expect(
        find.byKey(const Key('audioSetup_asioFallback_note')),
        findsNothing,
      );
    });
  });
}
