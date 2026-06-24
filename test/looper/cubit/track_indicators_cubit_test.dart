import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/cubit/track_indicators_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('TrackIndicatorsCubit', () {
    test('seeds on (true) so a default-on feature does not flash absent', () {
      expect(TrackIndicatorsCubit(settings: settings).state, isTrue);
    });

    blocTest<TrackIndicatorsCubit, bool>(
      'load restores a persisted false',
      setUp: () => settings.saveShowTrackIndicators(value: false),
      build: () => TrackIndicatorsCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [false],
    );

    blocTest<TrackIndicatorsCubit, bool>(
      'load is idempotent — restoring a persisted false emits only once',
      setUp: () => settings.saveShowTrackIndicators(value: false),
      build: () => TrackIndicatorsCubit(settings: settings),
      act: (cubit) async {
        await cubit.load();
        await cubit.load();
      },
      expect: () => [false],
    );

    blocTest<TrackIndicatorsCubit, bool>(
      'setEnabled persists and emits the new value',
      build: () => TrackIndicatorsCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: false),
      expect: () => [false],
      verify: (_) async =>
          expect(await settings.loadShowTrackIndicators(), isFalse),
    );

    blocTest<TrackIndicatorsCubit, bool>(
      'setEnabled to the current value does not emit but still persists',
      build: () => TrackIndicatorsCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: true),
      expect: () => <bool>[],
      verify: (_) async =>
          expect(await settings.loadShowTrackIndicators(), isTrue),
    );

    blocTest<TrackIndicatorsCubit, bool>(
      'toggle flips the value and persists it',
      build: () => TrackIndicatorsCubit(settings: settings),
      act: (cubit) => cubit.toggle(),
      expect: () => [false],
      verify: (_) async =>
          expect(await settings.loadShowTrackIndicators(), isFalse),
    );
  });
}
