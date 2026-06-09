import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;

  setUpAll(() => registerFallbackValue(Duration.zero));

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
  });

  group('RefreshRateCubit', () {
    test('defaults to 60 Hz', () {
      final cubit = RefreshRateCubit(
        repository: repository,
        settings: settings,
      );
      expect(cubit.state, 60);
    });

    blocTest<RefreshRateCubit, int>(
      'load restores the persisted rate and applies it to the repository',
      setUp: () => settings.saveRefreshHz(30),
      build: () => RefreshRateCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [30],
      verify: (_) {
        // 30 Hz -> 1_000_000 / 30 ≈ 33333 µs.
        verify(
          () => repository.setPollInterval(
            const Duration(microseconds: 33333),
          ),
        ).called(1);
      },
    );

    blocTest<RefreshRateCubit, int>(
      'setHz emits, persists, and applies the new rate',
      build: () => RefreshRateCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setHz(120),
      expect: () => [120],
      verify: (_) async {
        expect(await settings.loadRefreshHz(), 120);
        // 120 Hz -> 1_000_000 / 120 ≈ 8333 µs.
        verify(
          () => repository.setPollInterval(const Duration(microseconds: 8333)),
        ).called(1);
      },
    );

    blocTest<RefreshRateCubit, int>(
      'setHz to the current rate still persists but emits nothing new',
      build: () => RefreshRateCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setHz(60),
      expect: () => <int>[],
      verify: (_) async {
        expect(await settings.loadRefreshHz(), 60);
        verifyNever(() => repository.setPollInterval(any()));
      },
    );
  });
}
