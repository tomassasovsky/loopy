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
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setAutoRecord(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
  });

  RecordOptionsCubit build() =>
      RecordOptionsCubit(repository: repository, settings: settings);

  group('RecordOptionsCubit', () {
    test('defaults to both off', () {
      expect(build().state, const RecordOptions());
    });

    blocTest<RecordOptionsCubit, RecordOptions>(
      'load restores persisted options and applies them',
      setUp: () async {
        await settings.saveRecDub(value: true);
        await settings.saveAutoRecord(value: true);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [const RecordOptions(recDub: true, autoRecord: true)],
      verify: (_) {
        verify(() => repository.setRecDub(enabled: true)).called(1);
        verify(() => repository.setAutoRecord(enabled: true)).called(1);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'setRecDub emits, applies, and persists',
      build: build,
      act: (cubit) => cubit.setRecDub(value: true),
      expect: () => [const RecordOptions(recDub: true)],
      verify: (_) async {
        verify(() => repository.setRecDub(enabled: true)).called(1);
        expect(await settings.loadRecDub(), isTrue);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'setAutoRecord emits, applies, and persists',
      build: build,
      act: (cubit) => cubit.setAutoRecord(value: true),
      expect: () => [const RecordOptions(autoRecord: true)],
      verify: (_) async {
        verify(() => repository.setAutoRecord(enabled: true)).called(1);
        expect(await settings.loadAutoRecord(), isTrue);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'setDefaultMultiple emits, applies, and persists',
      build: build,
      act: (cubit) => cubit.setDefaultMultiple(2),
      expect: () => [const RecordOptions(defaultMultiple: 2)],
      verify: (_) async {
        verify(() => repository.setDefaultMultiple(multiple: 2)).called(1);
        expect(await settings.loadDefaultMultiple(), 2);
      },
    );
  });
}
