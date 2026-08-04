import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/pedal_firmware_cubit.dart';
import 'package:segno/update/view/pedal_firmware_gate.dart';
import 'package:update_repository/update_repository.dart';

/// Drives the real cubit rather than a stand-in, so these assertions are about
/// what a user would actually see for a given helper response.
class _FakeBackend implements PlatformUpdateBackend {
  _FakeBackend({this.pending, this.flashError});

  final String? pending;
  final Object? flashError;
  final progress = StreamController<double>();

  @override
  bool get isSupported => true;

  @override
  Future<String?> pendingPedalFirmware() async => pending;

  @override
  Stream<double> flashPedalFirmware() {
    if (flashError != null) return Stream.error(flashError!);
    return progress.stream;
  }

  @override
  String get channel => 'experimental';

  @override
  Future<void> setChannel(String channel) async {}

  @override
  Future<Version> currentVersion() async => Version.none;

  @override
  Future<Version> stagedVersion() async => Version.none;

  @override
  Future<UpdateManifest?> fetchManifest() async => null;

  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      const Stream.empty();

  @override
  Future<void> applyAndRestart() async {}
}

void main() {
  Future<PedalFirmwareCubit> pumpGate(
    WidgetTester tester,
    _FakeBackend backend,
  ) async {
    final cubit = PedalFirmwareCubit(
      updates: UpdateRepository(backend: backend),
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
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
    return cubit;
  }

  testWidgets('draws nothing while the answer is still unknown', (
    tester,
  ) async {
    // The check resolves in milliseconds on desktop; flashing a screen for it
    // would be worse than not having one.
    await pumpGate(tester, _FakeBackend());

    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });

  testWidgets('nothing pending leaves the looper alone', (tester) async {
    final cubit = await pumpGate(tester, _FakeBackend());

    await cubit.run();
    await tester.pump();

    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });

  testWidgets('shows progress and seals the looper off while flashing', (
    tester,
  ) async {
    final backend = _FakeBackend(pending: '0.4.0');
    final cubit = await pumpGate(tester, backend);

    unawaited(cubit.run());
    await tester.pump();
    await tester.pump();
    backend.progress.add(0.4);
    await tester.idle();
    await tester.pump();

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

    await backend.progress.close();
  });

  testWidgets('the gate brings its own Material', (tester) async {
    // The gate wraps the looper from `home:`, so it renders ABOVE the page's
    // Scaffold and inherits no Material. Without one of its own the text falls
    // back to the debug style and the button has nothing to paint on — which
    // is exactly how it shipped and what the console showed (#456).
    final backend = _FakeBackend(pending: '0.4.0');
    final cubit = await pumpGate(tester, backend);

    unawaited(cubit.run());
    await tester.pump();
    await tester.pump();

    expect(
      find.ancestor(
        of: find.byKey(const Key('pedal_firmware_gate')),
        matching: find.byType(Material),
      ),
      findsWidgets,
    );

    await backend.progress.close();
  });

  testWidgets('a failure explains itself and lets the user through', (
    tester,
  ) async {
    final cubit = await pumpGate(
      tester,
      _FakeBackend(pending: '0.4.0', flashError: Exception('avrdude failed')),
    );

    await cubit.run();
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.pedalFirmwareGateFailedTitle), findsOneWidget);
    expect(find.byKey(const Key('pedal_firmware_gate_progress')), findsNothing);

    await tester.tap(find.byKey(const Key('pedal_firmware_gate_continue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });
}
