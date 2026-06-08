import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:mocktail/mocktail.dart';
import 'package:session_repository/session_repository.dart';

class _MockSessionRepository extends Mock implements SessionRepository {}

const _session = Session(
  sampleRate: 48000,
  channels: 1,
  baseLengthFrames: 0,
  tempoBpm: 120,
  syncLoopToTempo: true,
  quantizeMode: QuantizeMode.bar,
  metronomeOn: false,
  countInEnabled: false,
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
        SessionState(status: SessionStatus.success, message: 'Session saved'),
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
        SessionState(status: SessionStatus.success, message: 'Session loaded'),
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
          message: 'Mixdown exported',
        ),
      ],
      verify: (_) => verify(
        () => repository.exportMixdown('/tmp/x/mixdown.wav'),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'emits failure when the repository throws',
      setUp: () =>
          when(() => repository.save(any())).thenThrow(Exception('disk full')),
      build: build,
      act: (cubit) => cubit.saveSession(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.failure,
          message: 'Exception: disk full',
        ),
      ],
    );
  });
}
