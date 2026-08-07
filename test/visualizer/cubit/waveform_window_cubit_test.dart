import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('WaveformWindowCubit', () {
    test('defaults to enabled and unfailed', () {
      expect(
        WaveformWindowCubit(settings: settings).state,
        const WaveformWindowState(),
      );
    });

    blocTest<WaveformWindowCubit, WaveformWindowState>(
      'setEnabled persists and emits the new value',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: false),
      expect: () => [const WaveformWindowState(enabled: false)],
      verify: (_) async =>
          expect(await settings.loadShowWaveformWindow(), isFalse),
    );

    blocTest<WaveformWindowCubit, WaveformWindowState>(
      'setEnabled to the current value does not emit but still persists',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: true),
      expect: () => <WaveformWindowState>[],
      verify: (_) async =>
          expect(await settings.loadShowWaveformWindow(), isTrue),
    );

    blocTest<WaveformWindowCubit, WaveformWindowState>(
      'toggle flips the value',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.toggle(),
      expect: () => [const WaveformWindowState(enabled: false)],
    );

    blocTest<WaveformWindowCubit, WaveformWindowState>(
      'load restores a persisted preference',
      setUp: () => settings.saveShowWaveformWindow(value: false),
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [const WaveformWindowState(enabled: false)],
    );

    blocTest<WaveformWindowCubit, WaveformWindowState>(
      'reportOpenFailed raises the flag once and no more',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit
        ..reportOpenFailed()
        ..reportOpenFailed(),
      expect: () => [const WaveformWindowState(openFailed: true)],
    );

    blocTest<WaveformWindowCubit, WaveformWindowState>(
      'retryOpen clears the failure — which is what re-syncs the window',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit
        ..reportOpenFailed()
        ..retryOpen(),
      expect: () => [
        const WaveformWindowState(openFailed: true),
        const WaveformWindowState(),
      ],
    );

    blocTest<WaveformWindowCubit, WaveformWindowState>(
      'retryOpen with nothing failed does not churn the window',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) => cubit.retryOpen(),
      expect: () => <WaveformWindowState>[],
    );

    blocTest<WaveformWindowCubit, WaveformWindowState>(
      'setting the preference again clears a standing failure',
      build: () => WaveformWindowCubit(settings: settings),
      act: (cubit) async {
        cubit.reportOpenFailed();
        await cubit.setEnabled(value: true);
      },
      expect: () => [
        const WaveformWindowState(openFailed: true),
        const WaveformWindowState(),
      ],
    );
  });
}
