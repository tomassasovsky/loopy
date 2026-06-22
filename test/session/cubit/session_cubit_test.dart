import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/session/session.dart';
import 'package:mocktail/mocktail.dart';
import 'package:session_repository/session_repository.dart';

class _MockSessionRepository extends Mock implements SessionRepository {}

const _session = Session(
  sampleRate: 48000,
  channels: 1,
  baseLengthFrames: 0,
  tracks: [],
);

void main() {
  late SessionRepository repository;

  setUp(() => repository = _MockSessionRepository());

  SessionCubit build() =>
      SessionCubit(repository: repository, directory: () async => '/tmp/x');

  group('SessionCubit', () {
    blocTest<SessionCubit, SessionState>(
      'saveSession emits working then success and saves to the directory',
      setUp: () => when(
        () => repository.save(any()),
      ).thenAnswer((_) async => _session),
      build: build,
      act: (cubit) => cubit.saveSession(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.saved,
        ),
      ],
      verify: (_) => verify(() => repository.save('/tmp/x')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'loadSession emits working then success',
      setUp: () => when(
        () => repository.load(any()),
      ).thenAnswer((_) async => _session),
      build: build,
      act: (cubit) => cubit.loadSession(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.loaded,
        ),
      ],
      verify: (_) => verify(() => repository.load('/tmp/x')).called(1),
    );

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
      'saveSession emits an unknown-classified failure when the repo throws',
      setUp: () =>
          when(() => repository.save(any())).thenThrow(Exception('disk full')),
      build: build,
      act: (cubit) => cubit.saveSession(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.unknown,
          errorMessage: 'Exception: disk full',
        ),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'loadSession emits an unknown-classified failure when the repo throws',
      setUp: () =>
          when(() => repository.load(any())).thenThrow(Exception('no bundle')),
      build: build,
      act: (cubit) => cubit.loadSession(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.unknown,
          errorMessage: 'Exception: no bundle',
        ),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'loadSession classifies a sample-rate mismatch',
      setUp: () => when(() => repository.load(any())).thenThrow(
        const SessionSampleRateMismatch(sessionRate: 44100, deviceRate: 48000),
      ),
      build: build,
      act: (cubit) => cubit.loadSession(),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.sampleRateMismatch),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'loadSession classifies an unsupported (newer) version',
      setUp: () => when(() => repository.load(any())).thenThrow(
        const SessionUnsupportedVersion(version: 2, supported: 1),
      ),
      build: build,
      act: (cubit) => cubit.loadSession(),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.unsupportedVersion),
      ],
    );
  });
}
