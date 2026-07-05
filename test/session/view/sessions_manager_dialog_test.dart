import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/gen/app_localizations.dart';
import 'package:loopy/session/session.dart';
import 'package:mocktail/mocktail.dart';
import 'package:session_repository/session_repository.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

void main() {
  late SessionCubit session;

  const two = [SessionSummary(name: 'A'), SessionSummary(name: 'B')];

  setUp(() {
    session = _MockSessionCubit();
    when(session.refreshSessions).thenAnswer((_) async {});
    when(() => session.loadNamed(any())).thenAnswer((_) async {});
    when(() => session.renameSession(any(), any())).thenAnswer((_) async {});
    when(() => session.deleteSession(any())).thenAnswer((_) async {});
    when(() => session.saveAs(any())).thenAnswer((_) async {});
  });

  Future<AppLocalizations> l10n() =>
      AppLocalizations.delegate.load(const Locale('en'));

  Future<void> openManager(
    WidgetTester tester, {
    SessionState state = const SessionState(),
  }) async {
    whenListen(
      session,
      const Stream<SessionState>.empty(),
      initialState: state,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SessionCubit>.value(
          value: session,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSessionsManager(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('SessionsManagerDialog', () {
    testWidgets('refreshes the catalog on open', (tester) async {
      await openManager(tester);
      verify(session.refreshSessions).called(1);
    });

    testWidgets('renders a row per saved session', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      expect(find.byKey(const Key('sessions_row_A')), findsOneWidget);
      expect(find.byKey(const Key('sessions_row_B')), findsOneWidget);
    });

    testWidgets('shows the empty state with no sessions', (tester) async {
      await openManager(tester);
      expect(find.byKey(const Key('sessions_empty')), findsOneWidget);
    });

    testWidgets('highlights the open session', (tester) async {
      await openManager(
        tester,
        state: const SessionState(sessions: two, currentSessionName: 'A'),
      );
      final open = tester.widget<ListTile>(
        find.byKey(const Key('sessions_row_A')),
      );
      expect(open.selected, isTrue);
      final other = tester.widget<ListTile>(
        find.byKey(const Key('sessions_row_B')),
      );
      expect(other.selected, isFalse);
    });

    testWidgets('tapping a row loads it and closes the manager', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_row_A')));
      await tester.pumpAndSettle();
      verify(() => session.loadNamed('A')).called(1);
      expect(find.byKey(const Key('sessions_manager')), findsNothing);
    });

    testWidgets('renaming a session fires the cubit', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_rename_A')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sessionName_field')),
        'Chorus',
      );
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      verify(() => session.renameSession('A', 'Chorus')).called(1);
    });

    testWidgets('renaming to an existing name shows an inline error', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_rename_A')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sessionName_field')), 'B');
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      final dup = (await l10n()).sessionNameDuplicate('B');
      expect(find.text(dup), findsOneWidget);
      verifyNever(() => session.renameSession(any(), any()));
    });

    testWidgets('deleting a session confirms then fires the cubit', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_delete_A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sessionDelete_confirm')));
      await tester.pumpAndSettle();
      verify(() => session.deleteSession('A')).called(1);
    });

    testWidgets('cancelling the delete confirm does nothing', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_delete_A')));
      await tester.pumpAndSettle();
      await tester.tap(find.text((await l10n()).cancel));
      await tester.pumpAndSettle();
      verifyNever(() => session.deleteSession(any()));
    });

    testWidgets('Save as… saves a new named session', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_saveAs')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sessionName_field')),
        'Bridge',
      );
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      verify(() => session.saveAs('Bridge')).called(1);
    });

    testWidgets('Save as… with a duplicate name shows an inline error', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_saveAs')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sessionName_field')), 'A');
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      final dup = (await l10n()).sessionNameDuplicate('A');
      expect(find.text(dup), findsOneWidget);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets('a name that sanitizes to nothing shows an inline error', (
      tester,
    ) async {
      await openManager(tester);
      await tester.tap(find.byKey(const Key('sessions_saveAs')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sessionName_field')), '!!!');
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      expect(find.text((await l10n()).sessionNameInvalid), findsOneWidget);
      verifyNever(() => session.saveAs(any()));
    });
  });
}
