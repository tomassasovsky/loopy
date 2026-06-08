import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/duplex_smoke/duplex_smoke.dart';
import 'package:loopy_engine/loopy_engine.dart';

import '../../helpers/helpers.dart';

void main() {
  group('DuplexSmokeView', () {
    late FakeAudioEngine engine;
    late DuplexSmokeCubit cubit;

    setUp(() {
      engine = FakeAudioEngine()
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          channels: 2,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0.5,
          inputPeak: 0.5,
          outputRms: 0.5,
          latencyState: LatencyState.idle,
          measuredLatencyMs: -1,
        );
      cubit = DuplexSmokeCubit(engine);
    });

    tearDown(() => cubit.close());

    Future<void> pumpView(WidgetTester tester) {
      return tester.pumpApp(
        BlocProvider.value(value: cubit, child: const DuplexSmokeView()),
      );
    }

    testWidgets('starts idle with a disabled measure button', (tester) async {
      await pumpView(tester);

      expect(find.text('Start passthrough'), findsOneWidget);
      final measureButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('duplexSmoke_measureLatency_button')),
      );
      expect(measureButton.enabled, isFalse);
    });

    testWidgets('tapping start runs the engine and shows the device', (
      tester,
    ) async {
      await pumpView(tester);

      await tester.tap(find.byKey(const Key('duplexSmoke_startStop_button')));
      await tester.pump();

      expect(engine.startCalls, 1);
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Fake Device'), findsOneWidget);

      cubit.stop(); // cancel the poll timer before the test ends
      await tester.pump();
    });

    testWidgets('measure button is enabled while running', (tester) async {
      await pumpView(tester);
      await tester.tap(find.byKey(const Key('duplexSmoke_startStop_button')));
      await tester.pump();

      final measureButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('duplexSmoke_measureLatency_button')),
      );
      expect(measureButton.enabled, isTrue);

      await tester.tap(
        find.byKey(const Key('duplexSmoke_measureLatency_button')),
      );
      await tester.pump();
      expect(engine.measureLatencyCalls, 1);

      cubit.stop(); // cancel the poll timer before the test ends
      await tester.pump();
    });

    testWidgets('renders an error message when start fails', (tester) async {
      engine.startResult = EngineResult.device;
      await pumpView(tester);

      await tester.tap(find.byKey(const Key('duplexSmoke_startStop_button')));
      await tester.pump();

      expect(find.byKey(const Key('duplexSmoke_error_text')), findsOneWidget);
    });

    testWidgets('shows a measured latency value when done', (tester) async {
      await pumpView(tester);
      await tester.tap(find.byKey(const Key('duplexSmoke_startStop_button')));
      await tester.pump();

      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        channels: 2,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: LatencyState.done,
        measuredLatencyMs: 6.25,
      );
      cubit.refresh();
      await tester.pump();

      expect(find.text('6.25 ms'), findsOneWidget);

      cubit.stop(); // cancel the poll timer before the test ends
      await tester.pump();
    });
  });
}
