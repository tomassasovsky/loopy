import 'package:bloc_test/bloc_test.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/network/network_tab.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _FakeBrightnessClient implements BrightnessClient {
  bool supported = true;
  double current = 0.8;
  final sets = <double>[];

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<double> get() async => current;

  @override
  Future<void> set(double value) async {
    sets.add(value);
    current = value;
  }
}

void main() {
  late SettingsRepository settings;
  late _FakeBrightnessClient brightness;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    brightness = _FakeBrightnessClient();
  });

  SettingsTrayCubit buildCubit() => SettingsTrayCubit(
    settings: settings,
    brightnessClient: brightness,
  );

  group('SettingsTrayCubit', () {
    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'open / closeTray / toggle',
      build: buildCubit,
      act: (cubit) => cubit
        ..open()
        ..closeTray()
        ..toggle()
        ..toggle(),
      expect: () => [
        const SettingsTrayState(dragProgress: 1),
        const SettingsTrayState(),
        const SettingsTrayState(dragProgress: 1),
        const SettingsTrayState(),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'dragTo clamps and settleFromDrag snaps',
      build: buildCubit,
      act: (cubit) => cubit
        ..dragTo(0.6)
        ..settleFromDrag()
        ..dragTo(0.4)
        ..settleFromDrag(),
      expect: () => [
        const SettingsTrayState(dragProgress: 0.6),
        const SettingsTrayState(dragProgress: 1),
        const SettingsTrayState(dragProgress: 0.4),
        const SettingsTrayState(),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'load restores brightness and applies when supported',
      build: buildCubit,
      setUp: () async {
        await settings.saveBrightness(0.55);
      },
      act: (cubit) => cubit.load(),
      expect: () => [const SettingsTrayState(brightness: 0.55)],
      verify: (_) {
        expect(brightness.sets, [0.55]);
      },
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'setBrightness persists and applies when supported',
      build: buildCubit,
      act: (cubit) async {
        await cubit.load();
        await cubit.setBrightness(0.3);
      },
      expect: () => [
        const SettingsTrayState(),
        const SettingsTrayState(brightness: 0.3),
      ],
      verify: (_) async {
        expect(await settings.loadBrightness(), 0.3);
        expect(brightness.sets.last, 0.3);
      },
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'setBrightness skips apply when unsupported',
      build: buildCubit,
      setUp: () {
        brightness.supported = false;
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.setBrightness(0.4);
      },
      expect: () => [
        const SettingsTrayState(),
        const SettingsTrayState(brightness: 0.4),
      ],
      verify: (_) {
        expect(brightness.sets, isEmpty);
      },
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'delegates brightness to DisplayBrightnessCubit when provided',
      build: () => SettingsTrayCubit(
        settings: settings,
        brightnessClient: brightness,
        displayBrightness: DisplayBrightnessCubit(
          settings: settings,
          client: brightness,
        ),
      ),
      setUp: () {
        brightness.supported = false;
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.setBrightness(0.35);
      },
      expect: () => [
        const SettingsTrayState(),
        const SettingsTrayState(brightness: 0.35),
      ],
      verify: (_) async {
        expect(await settings.loadBrightness(), 0.35);
        // DDC unsupported — DisplayBrightnessCubit still owns persistence;
        // software dim is applied by App via the cubit state.
        expect(brightness.sets, isEmpty);
      },
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'openWifi expands in-tray and closeTray resets to home',
      build: buildCubit,
      act: (cubit) => cubit
        ..openWifi()
        ..showHome()
        ..openBluetooth()
        ..closeTray(),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.network,
        ),
        const SettingsTrayState(
          dragProgress: 1,
        ),
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.network,
          networkTab: NetworkTab.bluetooth,
        ),
        // Closing resets the destination and NOT the tab: returning to
        // Network lands where it was left.
        const SettingsTrayState(networkTab: NetworkTab.bluetooth),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'showDestination switches face without touching dragProgress — the '
      'rail must never become a second say in whether the tray is open',
      build: buildCubit,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit
        ..showDestination(SettingsTrayDestination.tuner)
        ..showDestination(SettingsTrayDestination.home),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.tuner,
        ),
        const SettingsTrayState(dragProgress: 1),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'showDestination on a closed tray leaves it closed',
      build: buildCubit,
      act: (cubit) => cubit.showDestination(SettingsTrayDestination.network),
      expect: () => [
        const SettingsTrayState(
          destination: SettingsTrayDestination.network,
        ),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'the tray home shortcuts open the domain AT a tab',
      build: buildCubit,
      act: (cubit) => cubit
        ..openBluetooth()
        ..openWifi(),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.network,
          networkTab: NetworkTab.bluetooth,
        ),
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.network,
        ),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'showNetworkTab moves the tab and does NOT touch the destination — the '
      'strip is only reachable while Network is already showing',
      build: buildCubit,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit.showNetworkTab(NetworkTab.bluetooth),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          networkTab: NetworkTab.bluetooth,
        ),
      ],
    );
  });
}
