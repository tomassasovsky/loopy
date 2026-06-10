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

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
  });

  group('QuantizeCubit', () {
    test('defaults to off', () {
      final cubit = QuantizeCubit(repository: repository, settings: settings);
      expect(cubit.state, isFalse);
    });

    blocTest<QuantizeCubit, bool>(
      'load restores the persisted value and applies it to the repository',
      setUp: () => settings.saveQuantize(value: true),
      build: () => QuantizeCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [true],
      verify: (_) =>
          verify(() => repository.setQuantize(enabled: true)).called(1),
    );

    blocTest<QuantizeCubit, bool>(
      'setEnabled emits, persists, and applies the new value',
      build: () => QuantizeCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setEnabled(value: true),
      expect: () => [true],
      verify: (_) async {
        expect(await settings.loadQuantize(), isTrue);
        verify(() => repository.setQuantize(enabled: true)).called(1);
      },
    );

    blocTest<QuantizeCubit, bool>(
      'setEnabled to the current value still persists but emits nothing new',
      build: () => QuantizeCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setEnabled(value: false),
      expect: () => <bool>[],
      verify: (_) async {
        expect(await settings.loadQuantize(), isFalse);
        verifyNever(
          () => repository.setQuantize(enabled: any(named: 'enabled')),
        );
      },
    );
  });
}
