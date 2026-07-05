import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/looper.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('TracksCubit', () {
    test('defaults to generated names', () {
      final cubit = TracksCubit(settings: settings);
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

    blocTest<TracksCubit, TracksState>(
      'rename updates and persists the name',
      build: () => TracksCubit(settings: settings),
      act: (cubit) => cubit.rename(1, ' Guitar '),
      expect: () => [
        isA<TracksState>().having((s) => s.names[1], 'name', 'Guitar'),
      ],
      verify: (_) async => expect(await settings.loadTrackName(1), 'Guitar'),
    );

    blocTest<TracksCubit, TracksState>(
      'rename ignores blank input',
      build: () => TracksCubit(settings: settings),
      act: (cubit) => cubit.rename(0, '   '),
      expect: () => <TracksState>[],
    );

    blocTest<TracksCubit, TracksState>(
      'load restores persisted names',
      setUp: () => settings.saveTrackName(0, 'VOX'),
      build: () => TracksCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<TracksState>().having((s) => s.names[0], 'name', 'VOX'),
      ],
    );

    blocTest<TracksCubit, TracksState>(
      'rename during load keeps the renamed value',
      build: () => TracksCubit(settings: settings),
      act: (cubit) async {
        final loadFuture = cubit.load();
        await cubit.rename(0, 'BASS');
        await loadFuture;
      },
      expect: () => [
        isA<TracksState>().having((s) => s.names[0], 'name', 'BASS'),
      ],
      verify: (_) async => expect(await settings.loadTrackName(0), 'BASS'),
    );

    test('showIndicators seeds on (true) so a default-on feature does not '
        'flash absent', () {
      expect(TracksCubit(settings: settings).state.showIndicators, isTrue);
    });

    blocTest<TracksCubit, TracksState>(
      'setShowIndicators persists and emits the new value',
      build: () => TracksCubit(settings: settings),
      act: (cubit) => cubit.setShowIndicators(value: false),
      expect: () => [
        isA<TracksState>().having((s) => s.showIndicators, 'show', false),
      ],
      verify: (_) async =>
          expect(await settings.loadShowTrackIndicators(), isFalse),
    );

    blocTest<TracksCubit, TracksState>(
      'setShowIndicators to the current value does not emit but persists',
      build: () => TracksCubit(settings: settings),
      act: (cubit) => cubit.setShowIndicators(value: true),
      expect: () => <TracksState>[],
      verify: (_) async =>
          expect(await settings.loadShowTrackIndicators(), isTrue),
    );

    blocTest<TracksCubit, TracksState>(
      'load restores a persisted showIndicators = false',
      setUp: () => settings.saveShowTrackIndicators(value: false),
      build: () => TracksCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<TracksState>().having((s) => s.showIndicators, 'show', false),
      ],
    );
  });
}
