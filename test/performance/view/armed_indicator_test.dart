import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/performance/cubit/performance_recorder_cubit.dart';
import 'package:loopy/performance/view/armed_indicator.dart';

import '../../helpers/helpers.dart';

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

void main() {
  late _MockPerformanceRecorderCubit cubit;

  setUp(() {
    cubit = _MockPerformanceRecorderCubit();
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
        child: const Scaffold(body: ArmedIndicator()),
      ),
    );
  }

  testWidgets('renders nothing when not armed', (tester) async {
    await pump(tester, const PerformanceRecorderIdle());

    expect(find.byKey(const Key('tracks_armedIndicator')), findsNothing);
  });

  testWidgets('shows the elapsed time formatted mm:ss when armed', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderArmed(
        elapsed: Duration(minutes: 1, seconds: 5),
        overrun: false,
      ),
    );
    final strings = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.byKey(const Key('tracks_armedIndicator')), findsOneWidget);
    expect(find.text(strings.perfArmedElapsed('01:05')), findsOneWidget);
  });

  testWidgets('shows the overrun glitch icon when overrun is true', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderArmed(
        elapsed: Duration(seconds: 10),
        overrun: true,
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('hides the overrun glitch icon when overrun is false', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderArmed(
        elapsed: Duration(seconds: 10),
        overrun: false,
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('shows the low-disk icon when lowDiskWarning is true', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderArmed(
        elapsed: Duration(seconds: 10),
        overrun: false,
        lowDiskWarning: true,
      ),
    );

    expect(find.byIcon(Icons.sd_card_alert_outlined), findsOneWidget);
  });

  testWidgets('hides the low-disk icon when lowDiskWarning is false', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderArmed(
        elapsed: Duration(seconds: 10),
        overrun: false,
      ),
    );

    expect(find.byIcon(Icons.sd_card_alert_outlined), findsNothing);
  });

  testWidgets('shows both flags together when overrun and low disk co-occur', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderArmed(
        elapsed: Duration(seconds: 10),
        overrun: true,
        lowDiskWarning: true,
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.sd_card_alert_outlined), findsOneWidget);
  });
}
