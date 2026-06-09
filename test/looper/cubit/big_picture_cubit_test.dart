import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/looper.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('BigPictureCubit', () {
    test('defaults to channel 0 and generated names', () {
      final cubit = BigPictureCubit(settings: settings);
      expect(cubit.state.selectedChannel, 0);
      expect(cubit.state.names, [
        'TRACK 1',
        'TRACK 2',
        'TRACK 3',
        'TRACK 4',
        'TRACK 5',
        'TRACK 6',
        'TRACK 7',
        'TRACK 8',
      ]);
      expect(cubit.state.nameOf(2), 'TRACK 3');
    });

    blocTest<BigPictureCubit, BigPictureState>(
      'select changes the selected channel',
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) => cubit.select(2),
      expect: () => [
        isA<BigPictureState>().having((s) => s.selectedChannel, 'selected', 2),
      ],
    );

    blocTest<BigPictureCubit, BigPictureState>(
      'toggleMode switches between record and play',
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) => cubit
        ..toggleMode()
        ..toggleMode(),
      expect: () => [
        isA<BigPictureState>().having(
          (s) => s.mode,
          'mode',
          PerformanceMode.play,
        ),
        isA<BigPictureState>().having(
          (s) => s.mode,
          'mode',
          PerformanceMode.record,
        ),
      ],
    );

    blocTest<BigPictureCubit, BigPictureState>(
      'setDefaultPerformanceMode persists and applies the mode',
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) => cubit.setDefaultPerformanceMode(PerformanceMode.play),
      expect: () => [
        isA<BigPictureState>()
            .having((s) => s.defaultMode, 'defaultMode', PerformanceMode.play)
            .having((s) => s.mode, 'mode', PerformanceMode.play),
      ],
      verify: (_) async => expect(
        await settings.loadDefaultPerformanceMode(),
        PerformanceMode.play.token,
      ),
    );

    blocTest<BigPictureCubit, BigPictureState>(
      'load restores the default mode and boots the live mode into it',
      setUp: () =>
          settings.saveDefaultPerformanceMode(PerformanceMode.play.token),
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<BigPictureState>()
            .having((s) => s.defaultMode, 'defaultMode', PerformanceMode.play)
            .having((s) => s.mode, 'mode', PerformanceMode.play),
      ],
    );

    blocTest<BigPictureCubit, BigPictureState>(
      'toggleMode does not change the persisted default mode',
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) => cubit.toggleMode(),
      expect: () => [
        isA<BigPictureState>()
            .having((s) => s.mode, 'mode', PerformanceMode.play)
            .having(
              (s) => s.defaultMode,
              'defaultMode',
              PerformanceMode.record,
            ),
      ],
      verify: (_) async =>
          expect(await settings.loadDefaultPerformanceMode(), isNull),
    );

    blocTest<BigPictureCubit, BigPictureState>(
      'rename updates and persists the name',
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) => cubit.rename(1, ' Guitar '),
      expect: () => [
        isA<BigPictureState>().having((s) => s.names[1], 'name', 'Guitar'),
      ],
      verify: (_) async => expect(await settings.loadTrackName(1), 'Guitar'),
    );

    blocTest<BigPictureCubit, BigPictureState>(
      'rename ignores blank input',
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) => cubit.rename(0, '   '),
      expect: () => <BigPictureState>[],
    );

    blocTest<BigPictureCubit, BigPictureState>(
      'load restores persisted names',
      setUp: () => settings.saveTrackName(0, 'VOX'),
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<BigPictureState>().having((s) => s.names[0], 'name', 'VOX'),
      ],
    );

    blocTest<BigPictureCubit, BigPictureState>(
      'rename during load keeps the renamed value',
      build: () => BigPictureCubit(settings: settings),
      act: (cubit) async {
        final loadFuture = cubit.load();
        await cubit.rename(0, 'BASS');
        await loadFuture;
      },
      expect: () => [
        isA<BigPictureState>().having((s) => s.names[0], 'name', 'BASS'),
      ],
      verify: (_) async => expect(await settings.loadTrackName(0), 'BASS'),
    );
  });
}
