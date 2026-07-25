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

const _manifest = UpdateManifest(
  version: 2,
  bundle: 'loopy-appliance-2.raucb',
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
      const UpdateState(
        phase: UpdatePhase.upToDate,
        supported: true,
        currentVersion: 3,
        channel: 'experimental',
      ),
    );

    expect(find.text('v3'), findsOneWidget);
    expect(find.text('experimental'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_updatesAutoCheck_switch')),
      findsOneWidget,
    );
  });

  testWidgets('toggling auto-check persists via the cubit', (tester) async {
    await pump(
      tester,
      const UpdateState(
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

  testWidgets('available: shows notes and download row; tap downloads', (
    tester,
  ) async {
    await pump(
      tester,
      const UpdateState(
        phase: UpdatePhase.available,
        supported: true,
        currentVersion: 1,
        available: _manifest,
      ),
    );

    expect(find.text('wide splash'), findsOneWidget);
    final download = find.byKey(const Key('settings_updates_download'));
    expect(download, findsOneWidget);

    await tester.ensureVisible(download);
    await tester.tap(download);
    verify(cubit.startDownload).called(1);
  });

  testWidgets('downloading: renders a progress bar', (tester) async {
    await pump(
      tester,
      const UpdateState(
        phase: UpdatePhase.downloading,
        supported: true,
        progress: 0.5,
      ),
    );

    expect(
      find.byKey(const Key('settings_updates_progress')),
      findsOneWidget,
    );
  });

  testWidgets('idle: shows a check-now row that triggers a check', (
    tester,
  ) async {
    await pump(tester, const UpdateState(supported: true));

    final checkNow = find.byKey(const Key('settings_updates_checkNow'));
    await tester.ensureVisible(checkNow);
    await tester.tap(checkNow);
    verify(cubit.check).called(1);
  });

  testWidgets('upToDate: shows the latest-version message', (tester) async {
    await pump(
      tester,
      const UpdateState(
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

  testWidgets('error: shows the message and a retry check-now row', (
    tester,
  ) async {
    await pump(
      tester,
      const UpdateState(
        phase: UpdatePhase.error,
        supported: true,
        errorMessage: 'offline',
      ),
    );
    expect(find.text('offline'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_updates_checkNow')),
      findsOneWidget,
    );
  });

  testWidgets('staged: restart row asks to confirm before applying', (
    tester,
  ) async {
    await pump(
      tester,
      const UpdateState(
        phase: UpdatePhase.staged,
        supported: true,
        available: _manifest,
      ),
    );

    final restart = find.byKey(const Key('settings_updates_restart'));
    await tester.ensureVisible(restart);
    await tester.tap(restart);
    await tester.pumpAndSettle();

    // A confirmation dialog appears; applying only happens on confirm.
    verifyNever(cubit.applyAndRestart);
    await tester.tap(
      find.byKey(const Key('settings_updates_restart_confirm')),
    );
    await tester.pumpAndSettle();
    verify(cubit.applyAndRestart).called(1);
  });
}
