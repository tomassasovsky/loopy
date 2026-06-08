import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('UiModeCubit', () {
    test('defaults to desktop', () {
      expect(UiModeCubit(settings: settings).state, UiMode.desktop);
    });

    blocTest<UiModeCubit, UiMode>(
      'toggle switches to big picture and persists it',
      build: () => UiModeCubit(settings: settings),
      act: (cubit) => cubit.toggle(),
      expect: () => [UiMode.bigPicture],
      verify: (_) async {
        expect(await settings.loadUiMode(), UiMode.bigPicture.name);
      },
    );

    blocTest<UiModeCubit, UiMode>(
      'load restores the persisted mode',
      setUp: () => settings.saveUiMode(UiMode.bigPicture.name),
      build: () => UiModeCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [UiMode.bigPicture],
    );

    blocTest<UiModeCubit, UiMode>(
      'load with no saved mode keeps the default',
      build: () => UiModeCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => <UiMode>[],
    );

    blocTest<UiModeCubit, UiMode>(
      'setMode to the current mode does not emit but still persists',
      build: () => UiModeCubit(settings: settings),
      act: (cubit) => cubit.setMode(UiMode.desktop),
      expect: () => <UiMode>[],
      verify: (_) async {
        expect(await settings.loadUiMode(), UiMode.desktop.name);
      },
    );
  });
}
