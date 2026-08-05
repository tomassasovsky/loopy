import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/performance/view/armed_indicator.dart';
import 'package:segno/theme/theme.dart';

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

  testWidgets('the armed readout takes the DS chrome red, not the stage red', (
    tester,
  ) async {
    // #499 stage 3c. The design system splits red in two: `signal-rec` is the
    // stage (what a *track* is doing) and `rec` is UI chrome (the *app* is
    // capturing). This readout is chrome. Asserting the split rather than a
    // hex keeps it true through a palette migration — and asserting it is
    // *not* the stage red is the half that actually catches a regression,
    // since the two were the same colour before this stage.
    await pump(
      tester,
      const PerformanceRecorderArmed(
        elapsed: Duration(seconds: 10),
        overrun: false,
      ),
    );

    final context = tester.element(find.byType(ArmedIndicator));
    final surface = context.surface;
    final looper = Theme.of(context).extension<LooperTheme>()!;

    final icon = tester.widget<Icon>(
      find.byIcon(Icons.fiber_manual_record),
    );
    expect(icon.color, surface.rec);
    expect(
      icon.color,
      isNot(looper.recordColor),
      reason: 'chrome red must not fall back to the stage red',
    );

    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('tracks_armedIndicator')),
        matching: find.byType(Text),
      ),
    );
    expect(text.style?.color, surface.rec);
  });
}
