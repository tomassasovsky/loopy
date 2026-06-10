import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
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
      () => repository.setMonitorInputMask(any()),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorOutputMask(any()),
    ).thenReturn(EngineResult.ok);
  });

  MonitorCubit build() =>
      MonitorCubit(repository: repository, settings: settings);

  group('MonitorCubit', () {
    test('defaults to custom mode with input 0x1 / output 0x3', () {
      final cubit = build();
      expect(cubit.state.mode, MonitorMode.custom);
      expect(cubit.state.inputMask, 0x1);
      expect(cubit.state.outputMask, 0x3);
    });

    blocTest<MonitorCubit, MonitorState>(
      'load restores custom masks and applies them to the repository',
      setUp: () async {
        await settings.saveMonitorMode(MonitorMode.custom.token);
        await settings.saveMonitorInputMask(0x2);
        await settings.saveMonitorOutputMask(0x1);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const MonitorState(
          inputMask: 0x2,
          outputMask: 0x1,
        ),
      ],
      verify: (_) {
        verify(() => repository.setMonitorFollowTrack(null)).called(1);
        verify(() => repository.setMonitorInputMask(0x2)).called(1);
        verify(() => repository.setMonitorOutputMask(0x1)).called(1);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'load in follow mode follows the (default) selected track',
      setUp: () => settings.saveMonitorMode(MonitorMode.followSelected.token),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<MonitorState>().having(
          (s) => s.mode,
          'mode',
          MonitorMode.followSelected,
        ),
      ],
      verify: (_) =>
          verify(() => repository.setMonitorFollowTrack(0)).called(1),
    );

    blocTest<MonitorCubit, MonitorState>(
      'setMode(followSelected) follows the selected track and persists',
      build: build,
      act: (cubit) async {
        cubit.setSelectedChannel(2);
        await cubit.setMode(MonitorMode.followSelected);
      },
      expect: () => [
        isA<MonitorState>().having(
          (s) => s.mode,
          'mode',
          MonitorMode.followSelected,
        ),
      ],
      verify: (_) async {
        verify(() => repository.setMonitorFollowTrack(2)).called(1);
        expect(
          await settings.loadMonitorMode(),
          MonitorMode.followSelected.token,
        );
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setSelectedChannel only re-follows while in follow mode',
      build: build,
      act: (cubit) => cubit.setSelectedChannel(3), // still custom mode
      expect: () => <MonitorState>[],
      verify: (_) => verifyNever(() => repository.setMonitorFollowTrack(any())),
    );

    blocTest<MonitorCubit, MonitorState>(
      'setInputMask persists and applies while custom',
      build: build,
      act: (cubit) => cubit.setInputMask(0x3),
      expect: () => [
        isA<MonitorState>().having((s) => s.inputMask, 'inputMask', 0x3),
      ],
      verify: (_) async {
        verify(() => repository.setMonitorInputMask(0x3)).called(1);
        expect(await settings.loadMonitorInputMask(), 0x3);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setInputMask persists but does not apply while following a track',
      build: build,
      act: (cubit) async {
        await cubit.setMode(MonitorMode.followSelected);
        await cubit.setInputMask(0x3);
      },
      verify: (_) async {
        // The mask is saved but not pushed to the engine (follow overrides it).
        verifyNever(() => repository.setMonitorInputMask(any()));
        expect(await settings.loadMonitorInputMask(), 0x3);
      },
    );
  });
}
