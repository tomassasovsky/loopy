import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

PedalStateFrame _frame({
  int activeBank = 0,
  GlobalColor globalColor = GlobalColor.off,
  int loopLengthMicros = 0,
  PedalMode mode = PedalMode.rec,
  bool clearFadeActive = false,
  bool performanceArmed = false,
  Map<int, PedalTrackLed> leds = const {},
}) => PedalStateFrame(
  globalColor: globalColor,
  trackLeds: [
    for (var i = 0; i < PedalStateFrame.trackCount; i++)
      leds[i] ?? PedalTrackLed.off,
  ],
  activeBank: activeBank,
  selectedTrack: activeBank * 4,
  mode: mode,
  loopLengthMicros: loopLengthMicros,
  clearFadeActive: clearFadeActive,
  performanceArmed: performanceArmed,
);

const _recPlayKey = Key('pedalFaceplate_footswitch_recPlay');
const _undoKey = Key('pedalFaceplate_footswitch_undo');
const _encoderKey = Key('pedalFaceplate_encoder');
const _mainScreenKey = Key('mainScreen');
const _onScreenPedal = PedalOutput(
  id: kSimulatorOutputId,
  name: 'On-screen pedal',
);

void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(const LooperState());
    for (final stub in [
      () => looper.record(channel: any(named: 'channel')),
      () => looper.play(channel: any(named: 'channel')),
      () => looper.stopTrack(channel: any(named: 'channel')),
      () => looper.clear(channel: any(named: 'channel')),
      () => looper.undo(channel: any(named: 'channel')),
      () => looper.redo(channel: any(named: 'channel')),
    ]) {
      when(stub).thenReturn(EngineResult.ok);
    }
    when(
      () => looper.setMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
  });

  tearDown(() => looperStates.close());

  /// Pumps the faceplate over a real cubit + simulator transport, with
  /// placeholder screens so the embedded TracksView / waveform are not
  /// needed. Binds the on-screen output (so the plate shows) unless [bind] is
  /// false.
  Future<(PedalCubit, SimulatorPedalTransport)> pumpFaceplate(
    WidgetTester tester, {
    bool bind = true,
  }) async {
    final sim = SimulatorPedalTransport(inner: const NoopPedalTransport());
    final settings = SettingsRepository(store: FakeKeyValueStore());
    // The real control cubit: presses injected into the simulator decode
    // through the shared PedalRepository into the same control layer the app
    // wires (mode/cursor owned by ControlCubit).
    final pedalRepo = PedalRepository(sim);
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final control = ControlCubit(
      looper: looper,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
    );
    // NOT awaited: awaiting ControlCubit.close() here deadlocks (a
    // Flutter-test-binding stream-cancel interaction, tracked separately —
    // not a bug in this test or in ControlCubit itself; unawaited still
    // runs every cancellation to completion).
    addTearDown(() => unawaited(control.close()));
    final cubit = PedalCubit(
      pedal: pedalRepo,
      settings: settings,
      pollInterval: Duration.zero,
    );
    addTearDown(cubit.close); // disposes pedalRepo (the lifecycle owner)
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: RepositoryProvider<SimulatorPedalTransport>.value(
          value: sim,
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: cubit),
              BlocProvider.value(value: control),
            ],
            child: const Scaffold(
              body: PedalFaceplate(
                mainScreen: SizedBox(key: _mainScreenKey),
                waveformScreen: SizedBox(),
              ),
            ),
          ),
        ),
      ),
    );
    if (bind) {
      await cubit.selectOutput(_onScreenPedal);
      await tester.pumpAndSettle();
    }
    return (cubit, sim);
  }

  group('PedalFaceplate gate', () {
    testWidgets(
      'shows the bare main screen until the on-screen pedal is bound',
      (tester) async {
        final (cubit, _) = await pumpFaceplate(tester, bind: false);
        // Not bound: full-screen main view, no plate, no footswitches.
        expect(find.byKey(_mainScreenKey), findsOneWidget);
        expect(find.byKey(const Key('pedalFaceplate')), findsNothing);
        expect(find.byKey(_recPlayKey), findsNothing);

        await cubit.selectOutput(_onScreenPedal);
        await tester.pumpAndSettle();
        // Bound: the plate, with the main screen embedded and switches present.
        expect(find.byKey(const Key('pedalFaceplate')), findsOneWidget);
        expect(find.byKey(_recPlayKey), findsOneWidget);
        expect(find.byKey(_mainScreenKey), findsOneWidget);
      },
    );
  });

  group('PedalFaceplate rendering', () {
    testWidgets('shows a blank (all-off) plate before any frame arrives', (
      tester,
    ) async {
      await pumpFaceplate(tester);
      final led = tester.widget<Container>(
        find.byKey(const Key('pedalFaceplate_led_track0')),
      );
      expect(
        (led.decoration! as BoxDecoration).color,
        SurfaceTheme.dark.ledOff,
      );
    });

    testWidgets('renders track LEDs from the decoded frame', (tester) async {
      final (_, sim) = await pumpFaceplate(tester);
      sim.send(
        PedalCodec.encodeFrame(
          _frame(leds: {0: PedalTrackLed.red, 1: PedalTrackLed.green}),
        ),
      );
      await tester.pump();

      Color ledColor(int channel) =>
          (tester
                      .widget<Container>(
                        find.byKey(Key('pedalFaceplate_led_track$channel')),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      expect(ledColor(0), SurfaceTheme.dark.ledRed);
      expect(ledColor(1), SurfaceTheme.dark.ledGreen);
      expect(ledColor(2), SurfaceTheme.dark.ledOff);
    });

    testWidgets('maps the track LEDs to the active bank (B => 4..7)', (
      tester,
    ) async {
      final (_, sim) = await pumpFaceplate(tester);
      sim.send(
        PedalCodec.encodeFrame(
          _frame(activeBank: 1, leds: {4: PedalTrackLed.green}),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('pedalFaceplate_led_track4')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pedalFaceplate_led_track0')), findsNothing);
      expect(find.text('5'), findsNothing); // no visible track label
    });

    testWidgets('the ring shows the global activity color', (tester) async {
      final (_, sim) = await pumpFaceplate(tester);
      sim.send(PedalCodec.encodeFrame(_frame(globalColor: GlobalColor.red)));
      await tester.pump();

      final ring = tester.widget<Container>(find.byKey(_encoderKey));
      final border = (ring.decoration! as BoxDecoration).border! as Border;
      expect(border.top.color, SurfaceTheme.dark.ledRed);
    });

    Color ringBorderColor(WidgetTester tester) =>
        ((tester.widget<Container>(find.byKey(_encoderKey)).decoration!
                        as BoxDecoration)
                    .border!
                as Border)
            .top
            .color;

    testWidgets('the ring animates to off once the loop is cleared', (
      tester,
    ) async {
      final (_, sim) = await pumpFaceplate(tester);

      // Playing: the ring is lit in the activity colour.
      sim.send(
        PedalCodec.encodeFrame(
          _frame(globalColor: GlobalColor.green, loopLengthMicros: 1000000),
        ),
      );
      await tester.pump();
      expect(ringBorderColor(tester), SurfaceTheme.dark.ledGreen);

      // Cleared: activity off with no loop left — the ring goes dark (off).
      sim.send(PedalCodec.encodeFrame(_frame()));
      await tester.pump();
      expect(ringBorderColor(tester), SurfaceTheme.dark.ledOff);
    });

    testWidgets('a stop with a loop still loaded keeps the ring glow', (
      tester,
    ) async {
      final (_, sim) = await pumpFaceplate(tester);

      // Off but a loop remains (a Stop, not a Clear): the ring keeps its idle
      // glow rather than going fully dark.
      sim.send(PedalCodec.encodeFrame(_frame(loopLengthMicros: 1000000)));
      await tester.pump();
      expect(ringBorderColor(tester), SurfaceTheme.dark.ringGlow);
    });

    testWidgets('the BANK LED lights on bank B', (tester) async {
      final (_, sim) = await pumpFaceplate(tester);
      Color bankColor() =>
          (tester
                      .widget<Container>(
                        find.byKey(const Key('pedalFaceplate_led_bank')),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;

      sim.send(PedalCodec.encodeFrame(_frame()));
      await tester.pump();
      expect(bankColor(), SurfaceTheme.dark.ledOff);

      sim.send(PedalCodec.encodeFrame(_frame(activeBank: 1)));
      await tester.pump();
      expect(bankColor(), SurfaceTheme.dark.ledBlue);
    });

    testWidgets('the CLEAR LED lights while the clear button is held', (
      tester,
    ) async {
      final (_, sim) = await pumpFaceplate(tester);
      Color clearColor() =>
          (tester
                      .widget<Container>(
                        find.byKey(const Key('pedalFaceplate_led_clear')),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;

      sim.send(PedalCodec.encodeFrame(_frame()));
      await tester.pump();
      expect(clearColor(), SurfaceTheme.dark.ledOff);

      // The Clear LED tracks the held-clear bit (clearFadeActive), not the
      // ring's activity colour.
      sim.send(PedalCodec.encodeFrame(_frame(clearFadeActive: true)));
      await tester.pump();
      expect(clearColor(), SurfaceTheme.dark.ledRed);
    });

    group('the MODE status LED (D-PEDAL)', () {
      const modeLedKey = Key('pedalFaceplate_led_mode');

      testWidgets('is absent when performance recording is not armed', (
        tester,
      ) async {
        final (_, sim) = await pumpFaceplate(tester);

        sim.send(PedalCodec.encodeFrame(_frame()));
        await tester.pump();

        expect(find.byKey(modeLedKey), findsNothing);
      });

      testWidgets('is present and blinks while armed', (tester) async {
        final (_, sim) = await pumpFaceplate(tester);

        sim.send(PedalCodec.encodeFrame(_frame(performanceArmed: true)));
        await tester.pump();
        expect(find.byKey(modeLedKey), findsOneWidget);

        Color ledColor() =>
            (tester.widget<Container>(find.byKey(modeLedKey)).decoration!
                    as BoxDecoration)
                .color!;

        // _BlinkingLed starts lit, then alternates lit/dark every 400ms.
        expect(ledColor(), SurfaceTheme.dark.ledRed);
        await tester.pump(const Duration(milliseconds: 400));
        expect(ledColor(), Colors.transparent);
        await tester.pump(const Duration(milliseconds: 400));
        expect(ledColor(), SurfaceTheme.dark.ledRed);
      });

      testWidgets('disappears again once disarmed', (tester) async {
        final (_, sim) = await pumpFaceplate(tester);

        sim.send(PedalCodec.encodeFrame(_frame(performanceArmed: true)));
        await tester.pump();
        expect(find.byKey(modeLedKey), findsOneWidget);

        sim.send(PedalCodec.encodeFrame(_frame()));
        await tester.pump();
        expect(find.byKey(modeLedKey), findsNothing);
      });
    });
  });

  // These verify the faceplate's gesture wiring end-to-end: a widget
  // interaction injects onto the simulator, the real cubit decodes it, and the
  // looper is driven. The raw MIDI bytes the sim injects are covered
  // separately by simulator_pedal_transport_test.dart, so asserting the looper
  // effect here avoids observing `sim.input` — a broadcast subscription a
  // widget test's fake-async teardown cannot drain (it hangs the isolate).
  group('PedalFaceplate input', () {
    // Flushes the two async hops (sim input -> repository -> cubit) so the
    // looper call lands before the assertion.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    testWidgets('tapping REC/PLAY drives the looper', (tester) async {
      await pumpFaceplate(tester);
      await tester.tap(find.byKey(_recPlayKey));
      await settle(tester);
      // Rec mode (default): REC/PLAY advances the selected track (channel 0).
      verify(() => looper.record()).called(1);
    });

    testWidgets('undo tap undoes the selected track', (tester) async {
      await pumpFaceplate(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_undoKey)),
      );
      await tester.pump();
      await gesture.up(); // quick release == tap == undo
      await settle(tester);
      verify(() => looper.undo()).called(1);
    });

    testWidgets('a cancelled press still fires the release (undo)', (
      tester,
    ) async {
      await pumpFaceplate(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_undoKey)),
      );
      await tester.pump();
      // A cancelled pointer must still release the switch, so the undo tap
      // completes rather than leaving the button (and its timer) stuck.
      await gesture.cancel();
      await settle(tester);
      verify(() => looper.undo()).called(1);
    });

    testWidgets('dragging the encoder drives master gain', (tester) async {
      await pumpFaceplate(tester);
      await tester.drag(find.byKey(_encoderKey), const Offset(30, 0));
      await settle(tester);
      verify(() => looper.setMasterGain(any())).called(greaterThan(0));
    });

    testWidgets('leaving the tree releases a held switch', (tester) async {
      await pumpFaceplate(tester);
      // Hold UNDO (down, no up) — a switch whose release has an observable
      // effect — then tear the faceplate out of the tree.
      await tester.startGesture(tester.getCenter(find.byKey(_undoKey)));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await settle(tester);

      // The faceplate's deactivate() must releaseAll the held switch, so the
      // undo tap completes (no stuck note, no dangling long-press timer).
      verify(() => looper.undo()).called(1);
    });
  });
}
