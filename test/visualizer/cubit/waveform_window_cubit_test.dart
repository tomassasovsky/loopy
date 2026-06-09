import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/visualizer/cubit/waveform_window_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('WaveformWindowCubit', () {
    test('defaults to enabled', () {
      expect(WaveformWindowCubit(settings: settings).state, isTrue);
    });

    blocTest<WaveformWindowCubit, bool>(
      'setEnabled persists and emits the new value',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: false),
      expect: () => [false],
      verify: (_) async =>
          expect(await settings.loadShowWaveformWindow(), isFalse),
    );

    blocTest<WaveformWindowCubit, bool>(
      'setEnabled to the current value does not emit but still persists',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: true),
      expect: () => <bool>[],
      verify: (_) async =>
          expect(await settings.loadShowWaveformWindow(), isTrue),
    );

    blocTest<WaveformWindowCubit, bool>(
      'toggle flips the value',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.toggle(),
      expect: () => [false],
    );

    blocTest<WaveformWindowCubit, bool>(
      'load restores a persisted preference',
      setUp: () => settings.saveShowWaveformWindow(value: false),
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [false],
    );
  });
}
