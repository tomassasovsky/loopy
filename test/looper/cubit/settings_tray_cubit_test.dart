import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/cubit/settings_tray_cubit.dart';

void main() {
  group('SettingsTrayCubit', () {
    test('defaults to closed with the default brightness', () {
      final cubit = SettingsTrayCubit();
      expect(cubit.state.dragProgress, 0);
      expect(cubit.state.isNavigating, isFalse);
      expect(cubit.state.brightness, 0.8);
    });

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'dragTo emits the clamped progress',
      build: SettingsTrayCubit.new,
      act: (cubit) => cubit.dragTo(0.4),
      expect: () => [const SettingsTrayState(dragProgress: 0.4)],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'dragTo clamps below 0',
      build: SettingsTrayCubit.new,
      act: (cubit) => cubit.dragTo(-0.5),
      expect: () => [const SettingsTrayState()],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'dragTo clamps above 1',
      build: SettingsTrayCubit.new,
      act: (cubit) => cubit.dragTo(1.5),
      expect: () => [const SettingsTrayState(dragProgress: 1)],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'dragTo tracks a drag closed from an open tray',
      build: SettingsTrayCubit.new,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit.dragTo(0.9),
      expect: () => [const SettingsTrayState(dragProgress: 0.9)],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'settleFromDrag snaps open past the 50% threshold',
      build: SettingsTrayCubit.new,
      seed: () => const SettingsTrayState(dragProgress: 0.51),
      act: (cubit) => cubit.settleFromDrag(),
      expect: () => [const SettingsTrayState(dragProgress: 1)],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'settleFromDrag at exactly 50% snaps closed (distance-only, not >=)',
      build: SettingsTrayCubit.new,
      seed: () => const SettingsTrayState(dragProgress: 0.5),
      act: (cubit) => cubit.settleFromDrag(),
      expect: () => [const SettingsTrayState()],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'settleFromDrag snaps closed under the 50% threshold',
      build: SettingsTrayCubit.new,
      seed: () => const SettingsTrayState(dragProgress: 0.2),
      act: (cubit) => cubit.settleFromDrag(),
      expect: () => [const SettingsTrayState()],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'open sets dragProgress to 1',
      build: SettingsTrayCubit.new,
      act: (cubit) => cubit.open(),
      expect: () => [const SettingsTrayState(dragProgress: 1)],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'closeTray sets dragProgress to 0',
      build: SettingsTrayCubit.new,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit.closeTray(),
      expect: () => [const SettingsTrayState()],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'toggle opens a closed tray',
      build: SettingsTrayCubit.new,
      act: (cubit) => cubit.toggle(),
      expect: () => [const SettingsTrayState(dragProgress: 1)],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'toggle closes an open tray',
      build: SettingsTrayCubit.new,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit.toggle(),
      expect: () => [const SettingsTrayState()],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'beginNavigating / endNavigating toggle isNavigating',
      build: SettingsTrayCubit.new,
      act: (cubit) => cubit
        ..beginNavigating()
        ..endNavigating(),
      expect: () => [
        const SettingsTrayState(isNavigating: true),
        const SettingsTrayState(),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'setBrightness clamps to 0..1 and emits',
      build: SettingsTrayCubit.new,
      act: (cubit) => cubit
        ..setBrightness(0.3)
        ..setBrightness(-1)
        ..setBrightness(2),
      expect: () => [
        const SettingsTrayState(brightness: 0.3),
        const SettingsTrayState(brightness: 0),
        const SettingsTrayState(brightness: 1),
      ],
    );
  });
}
