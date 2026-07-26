import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/update/cubit/update_cubit.dart';
import 'package:loopy/update/view/updates_settings_section.dart';
import 'package:mocktail/mocktail.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';

class _MockUpdateCubit extends MockCubit<UpdateState> implements UpdateCubit {}

UpdateManifest _manifest() => UpdateManifest(
  version: Version.parse('0.2.0'),
  bundle: 'loopy-appliance-0.2.0.raucb',
  channel: 'experimental',
  notes: 'wide splash',
  size: 131803622,
);

void main() {
  late UpdateCubit cubit;

  setUp(() {
    cubit = _MockUpdateCubit();
    when(cubit.check).thenAnswer((_) async {});
    when(cubit.startDownload).thenAnswer((_) async {});
    when(cubit.applyAndRestart).thenAnswer((_) async {});
    when(
      () => cubit.setAutoCheck(value: any(named: 'value')),
    ).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, UpdateState state) {
    whenListen(cubit, const Stream<UpdateState>.empty(), initialState: state);
    return tester.pumpApp(
      BlocProvider<UpdateCubit>.value(
        value: cubit,
        child: const Scaffold(
          body: SingleChildScrollView(child: UpdatesSettingsSection()),
        ),
      ),
    );
  }

  testWidgets('shows installed version, channel, and the auto-check toggle', (
    tester,
  ) async {
    await pump(
      tester,
      UpdateState(
        phase: UpdatePhase.upToDate,
        supported: true,
        currentVersion: Version.parse('0.3.0'),
        channel: 'experimental',
      ),
    );

    expect(find.text('v0.3.0'), findsOneWidget);
    expect(find.text('experimental'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_updatesAutoCheck_switch')),
      findsOneWidget,
    );
  });

  testWidgets('toggling auto-check persists via the cubit', (tester) async {
    await pump(
      tester,
      UpdateState(
        supported: true,
        phase: UpdatePhase.upToDate,
        autoCheck: false,
      ),
    );

    await tester.tap(
      find.byKey(const Key('settings_updatesAutoCheck_switch')),
    );
    verify(() => cubit.setAutoCheck(value: true)).called(1);
  });

  testWidgets('available: shows notes and an action row; tap downloads', (
    tester,
  ) async {
    await pump(
      tester,
      UpdateState(
        phase: UpdatePhase.available,
        supported: true,
        currentVersion: Version.parse('0.1.0'),
        available: _manifest(),
      ),
    );

    expect(find.text('wide splash'), findsOneWidget);
    final action = find.byKey(const Key('settings_updates_action'));
    expect(action, findsOneWidget);

    await tester.ensureVisible(action);
    await tester.tap(action);
    verify(cubit.startDownload).called(1);
  });

  testWidgets(
    'downloading: the SAME action row persists, showing progress '
    '(not hidden/replaced)',
    (tester) async {
      await pump(
        tester,
        UpdateState(
          phase: UpdatePhase.downloading,
          supported: true,
          progress: 0.5,
          available: _manifest(),
        ),
      );

      expect(find.byKey(const Key('settings_updates_action')), findsOneWidget);
      expect(
        find.byKey(const Key('settings_updates_progress')),
        findsOneWidget,
      );

      // Busy: tapping the persistent row does nothing (disabled, not hidden).
      await tester.tap(find.byKey(const Key('settings_updates_action')));
      verifyNever(cubit.startDownload);
    },
  );

  testWidgets(
    'checking: the check-now row persists (disabled), not hidden or '
    'replaced by a bare label',
    (tester) async {
      await pump(tester, UpdateState(phase: UpdatePhase.checking));

      final checkNow = find.byKey(const Key('settings_updates_checkNow'));
      expect(checkNow, findsOneWidget);

      // Busy: tapping the persistent row does nothing (disabled, not hidden).
      await tester.tap(checkNow);
      verifyNever(cubit.check);
    },
  );

  testWidgets('idle: shows a check-now row that triggers a check', (
    tester,
  ) async {
    await pump(tester, UpdateState(supported: true));

    final checkNow = find.byKey(const Key('settings_updates_checkNow'));
    await tester.ensureVisible(checkNow);
    await tester.tap(checkNow);
    verify(cubit.check).called(1);
  });

  testWidgets('upToDate: the check-now row shows the latest-version message', (
    tester,
  ) async {
    await pump(
      tester,
      UpdateState(
        phase: UpdatePhase.upToDate,
        supported: true,
        channel: 'production',
      ),
    );
    expect(find.textContaining('production'), findsWidgets);
    expect(
      find.byKey(const Key('settings_updates_checkNow')),
      findsOneWidget,
    );
  });

  testWidgets(
    'error: shows the message; the check-now row persists, re-enabled '
    'to retry',
    (tester) async {
      await pump(
        tester,
        UpdateState(
          phase: UpdatePhase.error,
          supported: true,
          errorMessage: 'offline',
        ),
      );
      expect(find.text('offline'), findsOneWidget);
      final checkNow = find.byKey(const Key('settings_updates_checkNow'));
      expect(checkNow, findsOneWidget);

      await tester.tap(checkNow);
      verify(cubit.check).called(1);
    },
  );

  testWidgets(
    'staged: the SAME action row (as available/downloading) asks to '
    'confirm before applying',
    (tester) async {
      await pump(
        tester,
        UpdateState(
          phase: UpdatePhase.staged,
          supported: true,
          available: _manifest(),
        ),
      );

      final action = find.byKey(const Key('settings_updates_action'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();

      // A confirmation dialog appears; applying only happens on confirm.
      verifyNever(cubit.applyAndRestart);
      await tester.tap(
        find.byKey(const Key('settings_updates_restart_confirm')),
      );
      await tester.pumpAndSettle();
      verify(cubit.applyAndRestart).called(1);
    },
  );
}
