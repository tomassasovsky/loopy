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
    when(
      () => session.duplicateSession(any(), any()),
    ).thenAnswer((_) async {});
    when(() => session.saveAs(any())).thenAnswer((_) async {});
    when(session.save).thenAnswer((_) async {});
    when(() => session.exportMixdown()).thenAnswer((_) async {});
    when(() => session.exportStems()).thenAnswer((_) async {});
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

  // Opens session A's card overflow menu and taps [item] (rename/duplicate/
  // delete), settling the menu.
  Future<void> tapCardMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byKey(const Key('sessions_menu_A')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('sessions_${item}_A')));
    await tester.pumpAndSettle();
  }

  group('SessionsManagerDialog', () {
    testWidgets('refreshes the catalog on open', (tester) async {
      await openManager(tester);
      verify(session.refreshSessions).called(1);
    });

    testWidgets('renders a card per saved session', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      expect(find.byKey(const Key('sessions_card_A')), findsOneWidget);
      expect(find.byKey(const Key('sessions_card_B')), findsOneWidget);
    });

    testWidgets('shows the empty state with no sessions', (tester) async {
      await openManager(tester);
      expect(find.byKey(const Key('sessions_empty')), findsOneWidget);
    });

    testWidgets('the header shows the current session name or Unsaved', (
      tester,
    ) async {
      final strings = await l10n();
      await openManager(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('sessions_currentName'))).data,
        strings.sessionUnsaved,
      );
    });

    testWidgets('tapping a card loads it and closes the popup', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_card_A')));
      await tester.pumpAndSettle();
      verify(() => session.loadNamed('A')).called(1);
      expect(find.byKey(const Key('sessions_manager')), findsNothing);
    });

    testWidgets('renaming via the card menu fires the cubit', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tapCardMenu(tester, 'rename');
      await tester.enterText(
        find.byKey(const Key('sessionName_field')),
        'Chorus',
      );
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      verify(() => session.renameSession('A', 'Chorus')).called(1);
    });

    testWidgets('duplicating via the card menu fires the cubit', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tapCardMenu(tester, 'duplicate');
      await tester.enterText(
        find.byKey(const Key('sessionName_field')),
        'A copy',
      );
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      verify(() => session.duplicateSession('A', 'A copy')).called(1);
    });

    testWidgets('deleting via the card menu confirms then fires', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tapCardMenu(tester, 'delete');
      await tester.tap(find.byKey(const Key('sessionDelete_confirm')));
      await tester.pumpAndSettle();
      verify(() => session.deleteSession('A')).called(1);
    });

    testWidgets('cancelling the delete confirm does nothing', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tapCardMenu(tester, 'delete');
      await tester.tap(find.text((await l10n()).cancel));
      await tester.pumpAndSettle();
      verifyNever(() => session.deleteSession(any()));
    });

    testWidgets('a rename collision shows an inline error', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tapCardMenu(tester, 'rename');
      await tester.enterText(find.byKey(const Key('sessionName_field')), 'B');
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      final dup = (await l10n()).sessionNameDuplicate('B');
      expect(find.text(dup), findsOneWidget);
      verifyNever(() => session.renameSession(any(), any()));
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

    testWidgets('Save writes back when a session is open', (tester) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_save')));
      await tester.pumpAndSettle();
      verify(session.save).called(1);
    });

    testWidgets('Save with no open session opens Save-As', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessionName_field')), findsOneWidget);
      verifyNever(session.save);
    });

    testWidgets('the exports fire the cubit', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_exportMixdown')));
      await tester.pumpAndSettle();
      verify(() => session.exportMixdown()).called(1);
      await tester.tap(find.byKey(const Key('sessions_exportStems')));
      await tester.pumpAndSettle();
      verify(() => session.exportStems()).called(1);
    });
  });
}
