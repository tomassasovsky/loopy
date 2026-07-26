import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/update/cubit/update_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

class _MockUpdateRepository extends Mock implements UpdateRepository {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

final _v1 = Version.parse('0.1.0');
final _v2Number = Version.parse('0.2.0');
final _v2 = UpdateManifest(
  version: _v2Number,
  bundle: 'loopy-appliance-0.2.0.raucb',
  sha256: 's',
  channel: 'experimental',
);

void main() {
  late UpdateRepository updates;
  late SettingsRepository settings;

  setUpAll(() => registerFallbackValue(_v2));

  setUp(() {
    updates = _MockUpdateRepository();
    settings = _MockSettingsRepository();
    // Sensible defaults; individual tests override.
    when(() => updates.isSupported).thenReturn(true);
    when(() => updates.channel).thenReturn('experimental');
    when(() => updates.currentVersion()).thenAnswer((_) async => _v1);
    when(() => updates.checkForUpdate()).thenAnswer((_) async => null);
    when(() => settings.loadUpdateAutoCheck()).thenAnswer((_) async => true);
    when(
      () => settings.loadDismissedUpdateVersions(),
    ).thenAnswer((_) async => const {});
    when(
      () => settings.saveUpdateAutoCheck(value: any(named: 'value')),
    ).thenAnswer((_) async {});
    when(
      () => settings.saveDismissedUpdateVersions(any()),
    ).thenAnswer((_) async {});
  });

  UpdateCubit build() => UpdateCubit(updates: updates, settings: settings);

  group('load', () {
    blocTest<UpdateCubit, UpdateState>(
      'restores prefs and auto-checks when enabled + supported',
      setUp: () {
        when(
          () => settings.loadDismissedUpdateVersions(),
        ).thenAnswer((_) async => {Version.parse('0.5.0')});
        when(() => updates.checkForUpdate()).thenAnswer((_) async => _v2);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.supported, 'supported', true)
            .having((s) => s.channel, 'channel', 'experimental')
            .having((s) => s.currentVersion, 'currentVersion', _v1)
            .having((s) => s.autoCheck, 'autoCheck', true)
            .having((s) => s.dismissed, 'dismissed', {Version.parse('0.5.0')}),
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.checking,
        ),
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.available)
            .having((s) => s.available, 'available', _v2),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'does not auto-check when the preference is off',
      setUp: () => when(
        () => settings.loadUpdateAutoCheck(),
      ).thenAnswer((_) async => false),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>().having((s) => s.autoCheck, 'autoCheck', false),
      ],
      verify: (_) => verifyNever(() => updates.checkForUpdate()),
    );

    blocTest<UpdateCubit, UpdateState>(
      'does not auto-check on an unsupported platform',
      setUp: () => when(() => updates.isSupported).thenReturn(false),
      build: build,
      act: (cubit) => cubit.load(),
      verify: (_) => verifyNever(() => updates.checkForUpdate()),
    );

    test('is idempotent across repeated calls', () async {
      final cubit = build();
      await cubit.load();
      await cubit.load();
      verify(() => updates.currentVersion()).called(1);
    });
  });

  group('check', () {
    blocTest<UpdateCubit, UpdateState>(
      'emits upToDate when nothing newer is published',
      build: build,
      act: (cubit) => cubit.check(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.checking,
        ),
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.upToDate,
        ),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'emits error when the check throws',
      setUp: () => when(
        () => updates.checkForUpdate(),
      ).thenThrow(Exception('offline')),
      build: build,
      act: (cubit) => cubit.check(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.checking,
        ),
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.error)
            .having((s) => s.errorMessage, 'errorMessage', contains('offline')),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'is a no-op on an unsupported platform',
      setUp: () => when(() => updates.isSupported).thenReturn(false),
      build: build,
      act: (cubit) => cubit.check(),
      expect: () => const <UpdateState>[],
    );
  });

  group('startDownload', () {
    blocTest<UpdateCubit, UpdateState>(
      'streams progress then reaches staged',
      seed: () => UpdateState(available: _v2),
      setUp: () => when(
        () => updates.downloadAndStage(_v2),
      ).thenAnswer((_) => Stream.fromIterable([0.5, 1.0])),
      build: build,
      act: (cubit) => cubit.startDownload(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.downloading)
            .having((s) => s.progress, 'progress', 0),
        isA<UpdateState>().having((s) => s.progress, 'progress', 0.5),
        isA<UpdateState>().having((s) => s.progress, 'progress', 1.0),
        isA<UpdateState>().having((s) => s.phase, 'phase', UpdatePhase.staged),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'is a no-op when nothing is available',
      build: build,
      act: (cubit) => cubit.startDownload(),
      expect: () => const <UpdateState>[],
    );

    blocTest<UpdateCubit, UpdateState>(
      'emits error when staging fails',
      seed: () => UpdateState(available: _v2),
      setUp: () => when(
        () => updates.downloadAndStage(_v2),
      ).thenAnswer((_) => Stream.error(Exception('sha mismatch'))),
      build: build,
      act: (cubit) => cubit.startDownload(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.downloading,
        ),
        isA<UpdateState>().having((s) => s.phase, 'phase', UpdatePhase.error),
      ],
    );
  });

  group('dismiss', () {
    blocTest<UpdateCubit, UpdateState>(
      'adds the version and persists',
      seed: () => UpdateState(dismissed: {Version.parse('0.1.0')}),
      build: build,
      act: (cubit) => cubit.dismiss(_v2Number),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.dismissed,
          'dismissed',
          {Version.parse('0.1.0'), _v2Number},
        ),
      ],
      verify: (_) => verify(
        () => settings.saveDismissedUpdateVersions({
          Version.parse('0.1.0'),
          _v2Number,
        }),
      ).called(1),
    );

    blocTest<UpdateCubit, UpdateState>(
      'is a no-op when already dismissed',
      seed: () => UpdateState(dismissed: {_v2Number}),
      build: build,
      act: (cubit) => cubit.dismiss(_v2Number),
      expect: () => const <UpdateState>[],
      verify: (_) =>
          verifyNever(() => settings.saveDismissedUpdateVersions(any())),
    );
  });

  group('setAutoCheck', () {
    blocTest<UpdateCubit, UpdateState>(
      'emits and persists the new value',
      seed: UpdateState.new,
      build: build,
      act: (cubit) => cubit.setAutoCheck(value: false),
      expect: () => [
        isA<UpdateState>().having((s) => s.autoCheck, 'autoCheck', false),
      ],
      verify: (_) =>
          verify(() => settings.saveUpdateAutoCheck(value: false)).called(1),
    );
  });

  group('applyAndRestart', () {
    test('delegates to the repository', () async {
      when(() => updates.applyAndRestart()).thenAnswer((_) async {});
      await build().applyAndRestart();
      verify(() => updates.applyAndRestart()).called(1);
    });
  });
}
