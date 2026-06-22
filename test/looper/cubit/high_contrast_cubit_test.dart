import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/cubit/high_contrast_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('HighContrastCubit', () {
    test('defaults to off', () {
      expect(HighContrastCubit(settings: settings).state, isFalse);
    });

    blocTest<HighContrastCubit, bool>(
      'setEnabled persists and emits the new value',
      build: () => HighContrastCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: true),
      expect: () => [true],
      verify: (_) async => expect(await settings.loadHighContrast(), isTrue),
    );

    blocTest<HighContrastCubit, bool>(
      'setEnabled to the current value does not emit but still persists',
      build: () => HighContrastCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: false),
      expect: () => <bool>[],
      verify: (_) async => expect(await settings.loadHighContrast(), isFalse),
    );

    blocTest<HighContrastCubit, bool>(
      'toggle flips the value',
      build: () => HighContrastCubit(settings: settings),
      act: (cubit) => cubit.toggle(),
      expect: () => [true],
    );

    blocTest<HighContrastCubit, bool>(
      'load restores a persisted preference',
      setUp: () => settings.saveHighContrast(value: true),
      build: () => HighContrastCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [true],
    );
  });
}
