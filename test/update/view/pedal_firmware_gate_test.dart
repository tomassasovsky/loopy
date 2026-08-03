import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/update/cubit/pedal_firmware_cubit.dart';
import 'package:loopy/update/view/pedal_firmware_gate.dart';

class _StubCubit extends Cubit<PedalFirmwareState>
    implements PedalFirmwareCubit {
  _StubCubit(super.initialState);

  int dismissCalls = 0;

  @override
  void dismiss() {
    dismissCalls++;
    emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
  }

  @override
  Future<void> run() async {}
}

void main() {
  Future<void> pumpGate(WidgetTester tester, _StubCubit cubit) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<PedalFirmwareCubit>.value(
          value: cubit,
          child: const PedalFirmwareGate(
            child: Text('looper', key: Key('looper')),
          ),
        ),
      ),
    );
  }

  testWidgets('draws nothing while the answer is still unknown', (
    tester,
  ) async {
    // The check resolves in milliseconds on desktop; flashing a screen for it
    // would be worse than not having one.
    final cubit = _StubCubit(const PedalFirmwareState());
    addTearDown(cubit.close);

    await pumpGate(tester, cubit);

    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });

  testWidgets('shows progress and seals the looper off while flashing', (
    tester,
  ) async {
    final cubit = _StubCubit(
      const PedalFirmwareState(
        stage: PedalFirmwareStage.flashing,
        version: '0.4.0',
        progress: 0.4,
      ),
    );
    addTearDown(cubit.close);

    await pumpGate(tester, cubit);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(l10n.pedalFirmwareGateTitle), findsOneWidget);
    expect(find.textContaining('0.4.0'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('pedal_firmware_gate_progress')),
          )
          .value,
      0.4,
    );
    // A non-dismissible barrier, not just a panel drawn on top: a stray tap on
    // a transport control while the pedal is in its bootloader must not reach
    // the looper.
    final barrier = tester.widget<ModalBarrier>(
      find.byKey(const Key('pedal_firmware_gate_barrier')),
    );
    expect(barrier.dismissible, isFalse);
  });

  testWidgets('a failure explains itself and lets the user through', (
    tester,
  ) async {
    final cubit = _StubCubit(
      const PedalFirmwareState(
        stage: PedalFirmwareStage.failed,
        version: '0.4.0',
        error: 'avrdude failed',
      ),
    );
    addTearDown(cubit.close);

    await pumpGate(tester, cubit);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(l10n.pedalFirmwareGateFailedTitle), findsOneWidget);
    expect(
      find.byKey(const Key('pedal_firmware_gate_progress')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('pedal_firmware_gate_continue')));
    await tester.pumpAndSettle();

    expect(cubit.dismissCalls, 1);
    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });
}
