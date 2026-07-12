import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/session/session.dart';
import 'package:mocktail/mocktail.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:session_repository/session_repository.dart';

class _MockSessionRepository extends Mock implements SessionRepository {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockPerformanceRepository extends Mock
    implements PerformanceRepository {}

const _session = Session(
  sampleRate: 48000,
  channels: 1,
  baseLengthFrames: 0,
  tracks: [],
);

void main() {
  late SessionRepository repository;
  late LooperRepository looper;
  late PerformanceRepository performance;

  setUpAll(() {
    registerFallbackValue(const SessionRig());
    registerFallbackValue(const SessionChains());
  });

  setUp(() {
    repository = _MockSessionRepository();
    looper = _MockLooperRepository();
    performance = _MockPerformanceRepository();
    // Default chain getters so the save path's _captureChains() has something
    // to read; individual tests override as needed.
    when(looper.allLaneEffects).thenReturn(const {});
    when(looper.allMonitors).thenReturn(const {});
    // loadNamed's auto-disarm-before-load orchestration; a no-op success by
    // default since nothing is armed in these tests.
    when(
      performance.disarmAndFinalize,
    ).thenAnswer((_) async => EngineResult.ok);
  });

  SessionCubit build() => SessionCubit(
    repository: repository,
    looper: looper,
    performance: performance,
    exportDirectory: () async => '/tmp/x',
  );

  group('SessionCubit exports', () {
    blocTest<SessionCubit, SessionState>(
      'exportMixdown writes mixdown.wav under the directory',
      setUp: () => when(
        () => repository.exportMixdown(any()),
      ).thenAnswer((_) async {}),
      build: build,
      act: (cubit) => cubit.exportMixdown(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.mixdownExported,
        ),
      ],
      verify: (_) => verify(
        () => repository.exportMixdown('/tmp/x/mixdown.wav'),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'exportStems writes stems under a stems folder',
      setUp: () => when(
        () => repository.exportStems(any()),
      ).thenAnswer((_) async {}),
      build: build,
      act: (cubit) => cubit.exportStems(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.stemsExported,
        ),
      ],
      verify: (_) =>
          verify(() => repository.exportStems('/tmp/x/stems')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'exportMixdown emits an unknown-classified failure when the repo throws',
      setUp: () => when(
        () => repository.exportMixdown(any()),
      ).thenThrow(Exception('disk full')),
      build: build,
      act: (cubit) => cubit.exportMixdown(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.unknown,
          errorMessage: 'Exception: disk full',
        ),
      ],
    );
  });

  group('load failure classification', () {
    void stubRead(Object error) {
      when(
        () => repository.bundlePath(any()),
      ).thenAnswer((_) async => '/root/x');
      when(() => repository.read(any())).thenThrow(error);
    }

    blocTest<SessionCubit, SessionState>(
      'loadNamed classifies a sample-rate mismatch',
      setUp: () => stubRead(
        const SessionSampleRateMismatch(sessionRate: 44100, deviceRate: 48000),
      ),
      build: build,
      act: (cubit) => cubit.loadNamed('X'),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.sampleRateMismatch),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'loadNamed classifies an unsupported (newer) version',
      setUp: () => stubRead(
        const SessionUnsupportedVersion(version: 2, supported: 1),
      ),
      build: build,
      act: (cubit) => cubit.loadNamed('X'),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.unsupportedVersion),
      ],
    );
  });

  group('named sessions', () {
    const summaries = [SessionSummary(name: 'A'), SessionSummary(name: 'B')];

    void stubCatalog({List<SessionSummary> list = summaries}) {
      when(
        () => repository.bundlePath(any()),
      ).thenAnswer((inv) async => '/root/${inv.positionalArguments.first}');
      when(repository.listSessions).thenAnswer((_) async => list);
      when(
        () => repository.save(any(), chains: any(named: 'chains')),
      ).thenAnswer((_) async => _session);
    }

    blocTest<SessionCubit, SessionState>(
      'saveAs writes a new named session, sets it current, and refreshes',
      setUp: stubCatalog,
      build: build,
      act: (cubit) => cubit.saveAs('New'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.saved)
            .having((s) => s.currentSessionName, 'current', 'New')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) => verify(
        () => repository.save('/root/New', chains: any(named: 'chains')),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'saveAs rejects a duplicate slug with nameCollision, writing nothing',
      setUp: () => stubCatalog(list: const [SessionSummary(name: 'Taken')]),
      build: build,
      act: (cubit) => cubit.saveAs('Taken!'), // folds to the existing "Taken"
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.nameCollision),
      ],
      verify: (_) => verifyNever(
        () => repository.save(any(), chains: any(named: 'chains')),
      ),
    );

    blocTest<SessionCubit, SessionState>(
      'save writes back to the open session with no prompt',
      setUp: stubCatalog,
      seed: () => const SessionState(currentSessionName: 'Open'),
      build: build,
      act: (cubit) => cubit.save(),
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.working)
            .having((s) => s.currentSessionName, 'current', 'Open'),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.saved)
            .having((s) => s.currentSessionName, 'current', 'Open'),
      ],
      verify: (_) => verify(
        () => repository.save('/root/Open', chains: any(named: 'chains')),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'save with no open session signals saveAsRequested and does not save',
      setUp: stubCatalog,
      build: build,
      act: (cubit) => cubit.save(),
      expect: () => [
        isA<SessionState>()
            .having((s) => s.outcome, 'outcome', SessionOutcome.saveAsRequested)
            .having((s) => s.currentSessionName, 'current', isNull),
      ],
      verify: (_) => verifyNever(
        () => repository.save(any(), chains: any(named: 'chains')),
      ),
    );

    blocTest<SessionCubit, SessionState>(
      'loadNamed reads, applies through the looper, sets current, refreshes',
      setUp: () {
        stubCatalog();
        when(() => repository.read(any())).thenAnswer(
          (_) async =>
              (session: _session, laneStems: <(int, int), List<Float32List>>{}),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {});
      },
      build: build,
      act: (cubit) => cubit.loadNamed('A'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.loaded)
            .having((s) => s.currentSessionName, 'current', 'A')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) {
        verify(() => repository.read('/root/A')).called(1);
        verify(() => looper.applySession(any())).called(1);
        verify(performance.disarmAndFinalize).called(1);
      },
    );

    blocTest<SessionCubit, SessionState>(
      'loadNamed auto-disarms and finalizes before reading the bundle '
      '(D-ORCHESTRATE)',
      setUp: () {
        stubCatalog();
        when(() => repository.read(any())).thenAnswer(
          (_) async =>
              (session: _session, laneStems: <(int, int), List<Float32List>>{}),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {});
      },
      build: build,
      act: (cubit) => cubit.loadNamed('A'),
      verify: (_) {
        verifyInOrder([
          performance.disarmAndFinalize,
          () => repository.read(any()),
          () => looper.applySession(any()),
        ]);
      },
    );

    blocTest<SessionCubit, SessionState>(
      'renameSession makes the current pointer follow a rename of the open one',
      setUp: () {
        stubCatalog();
        when(
          () => repository.renameSession(any(), any()),
        ).thenAnswer((_) async {});
      },
      seed: () => const SessionState(currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.renameSession('A', 'A2'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.renamed)
            .having((s) => s.currentSessionName, 'current', 'A2'),
      ],
      verify: (_) =>
          verify(() => repository.renameSession('A', 'A2')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'renameSession leaves the current pointer alone for a non-open session',
      setUp: () {
        stubCatalog();
        when(
          () => repository.renameSession(any(), any()),
        ).thenAnswer((_) async {});
      },
      seed: () => const SessionState(currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.renameSession('B', 'B2'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.currentSessionName, 'current', 'A'),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'deleteSession clears the current pointer and never touches the rig',
      setUp: () {
        stubCatalog(list: const [SessionSummary(name: 'B')]);
        when(() => repository.deleteSession(any())).thenAnswer((_) async {});
      },
      seed: () =>
          const SessionState(currentSessionName: 'A', sessions: summaries),
      build: build,
      act: (cubit) => cubit.deleteSession('A'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.deleted)
            .having((s) => s.currentSessionName, 'current', isNull)
            .having((s) => s.sessions, 'sessions', const [
              SessionSummary(name: 'B'),
            ]),
      ],
      verify: (_) {
        verify(() => repository.deleteSession('A')).called(1);
        verifyNever(() => looper.applySession(any()));
      },
    );

    blocTest<SessionCubit, SessionState>(
      'duplicateSession copies the bundle and refreshes the catalog',
      setUp: () {
        stubCatalog();
        when(
          () => repository.duplicateSession(any(), any()),
        ).thenAnswer((_) async {});
      },
      seed: () =>
          const SessionState(currentSessionName: 'A', sessions: summaries),
      build: build,
      act: (cubit) => cubit.duplicateSession('A', 'A copy'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.saved)
            // The open session is unchanged — a duplicate is a disk copy.
            .having((s) => s.currentSessionName, 'current', 'A')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) =>
          verify(() => repository.duplicateSession('A', 'A copy')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'saveAs with an unsanitizable name fails (invalid), writing nothing',
      setUp: stubCatalog,
      build: build,
      act: (cubit) => cubit.saveAs('   '),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.unknown),
      ],
      verify: (_) => verifyNever(
        () => repository.save(any(), chains: any(named: 'chains')),
      ),
    );

    blocTest<SessionCubit, SessionState>(
      'refreshSessions loads the catalog into state',
      setUp: stubCatalog,
      build: build,
      act: (cubit) => cubit.refreshSessions(),
      expect: () => [
        isA<SessionState>().having((s) => s.sessions, 'sessions', summaries),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'a write-back preserves the open session + catalog across the '
      'transition (C1)',
      setUp: () {
        when(
          () => repository.bundlePath(any()),
        ).thenAnswer((_) async => '/root/Open');
        when(
          () => repository.save(any(), chains: any(named: 'chains')),
        ).thenAnswer((_) async => _session);
      },
      seed: () =>
          const SessionState(currentSessionName: 'Open', sessions: summaries),
      build: build,
      act: (cubit) => cubit.save(), // write-back to the open session
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.working)
            .having((s) => s.currentSessionName, 'current', 'Open')
            .having((s) => s.sessions, 'sessions', summaries),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.saved)
            .having((s) => s.currentSessionName, 'current', 'Open')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
    );
  });
}
