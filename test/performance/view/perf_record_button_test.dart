import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/performance/cubit/performance_recorder_cubit.dart';
import 'package:loopy/performance/view/perf_record_button.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/helpers.dart';

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

void main() {
  late _MockPerformanceRecorderCubit cubit;

  setUp(() {
    cubit = _MockPerformanceRecorderCubit();
    when(cubit.toggleArm).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, PerformanceRecorderState state) async {
    whenListen(
      cubit,
      const Stream<PerformanceRecorderState>.empty(),
      initialState: state,
    );
    await tester.pumpApp(
      BlocProvider<PerformanceRecorderCubit>.value(
        value: cubit,
        child: const Scaffold(body: PerfRecordButton()),
      ),
    );
  }

  Future<AppLocalizations> l10n() =>
      AppLocalizations.delegate.load(const Locale('en'));

  testWidgets('idle: enabled, armed tooltip reads "arm"', (tester) async {
    await pump(tester, const PerformanceRecorderIdle());
    final strings = await l10n();

    final button = tester.widget<IconButton>(
      find.byKey(const Key('tracks_perfRecord')),
    );
    expect(button.onPressed, isNotNull);
    expect(button.tooltip, strings.perfArm);
    expect(find.byIcon(Icons.fiber_manual_record_outlined), findsOneWidget);
  });

  testWidgets(
    'armed: enabled, tooltip reads "disarm", uses the record color',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderArmed(
          elapsed: Duration(seconds: 3),
          overrun: false,
        ),
      );
      final strings = await l10n();

      final button = tester.widget<IconButton>(
        find.byKey(const Key('tracks_perfRecord')),
      );
      expect(button.onPressed, isNotNull);
      expect(button.tooltip, strings.perfDisarm);
      expect(find.byIcon(Icons.fiber_manual_record), findsOneWidget);
    },
  );

  testWidgets(
    'disabled while finalizing, with the "still rendering" tooltip',
    (tester) async {
      await pump(tester, const PerformanceRecorderFinalizing());
      final strings = await l10n();

      final button = tester.widget<IconButton>(
        find.byKey(const Key('tracks_perfRecord')),
      );
      expect(button.onPressed, isNull);
      expect(button.tooltip, strings.perfArmDisabledRendering);
    },
  );

  testWidgets(
    'disabled while rendering, with the "still rendering" tooltip',
    (tester) async {
      await pump(tester, const PerformanceRecorderRendering(percent: 42));
      final strings = await l10n();

      final button = tester.widget<IconButton>(
        find.byKey(const Key('tracks_perfRecord')),
      );
      expect(button.onPressed, isNull);
      expect(button.tooltip, strings.perfArmDisabledRendering);
    },
  );

  testWidgets(
    'disabled while a boot-recovery prompt is unresolved',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderIdle(recoveryDirectory: '/exports/perf-x'),
      );

      final button = tester.widget<IconButton>(
        find.byKey(const Key('tracks_perfRecord')),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('tapping the enabled button dispatches toggleArm', (
    tester,
  ) async {
    await pump(tester, const PerformanceRecorderIdle());

    await tester.tap(find.byKey(const Key('tracks_perfRecord')));
    await tester.pump();

    verify(cubit.toggleArm).called(1);
  });

  testWidgets(
    'completed: enabled, and tapping it dispatches toggleArm (D-REARM — '
    'the button stays wired for this state, not just visually enabled; the '
    'cubit-level toggleArm tests in performance_recorder_cubit_test.dart are '
    'what prove arming again actually succeeds)',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-x'),
        ),
      );

      final button = tester.widget<IconButton>(
        find.byKey(const Key('tracks_perfRecord')),
      );
      expect(button.onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('tracks_perfRecord')));
      await tester.pump();

      verify(cubit.toggleArm).called(1);
    },
  );
}
