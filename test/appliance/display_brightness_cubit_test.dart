import 'package:bloc_test/bloc_test.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _FakeBrightnessClient implements BrightnessClient {
  bool supported = true;
  final sets = <double>[];

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<double> get() async => 0.8;

  @override
  Future<void> set(double value) async => sets.add(value);
}

void main() {
  late SettingsRepository settings;
  late _FakeBrightnessClient client;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    client = _FakeBrightnessClient();
  });

  DisplayBrightnessCubit build() => DisplayBrightnessCubit(
    settings: settings,
    client: client,
  );

  group('DisplayBrightnessCubit', () {
    blocTest<DisplayBrightnessCubit, double>(
      'load restores persisted brightness and applies DDC when supported',
      setUp: () async {
        await settings.saveBrightness(0.55);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [0.55],
      verify: (_) {
        expect(client.sets, [0.55]);
      },
    );

    blocTest<DisplayBrightnessCubit, double>(
      'load skips DDC when unsupported (software dim still uses state)',
      setUp: () async {
        client.supported = false;
        await settings.saveBrightness(0.4);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [0.4],
      verify: (_) {
        expect(client.sets, isEmpty);
      },
    );

    blocTest<DisplayBrightnessCubit, double>(
      'setBrightness persists and applies DDC when supported',
      build: build,
      act: (cubit) async {
        // First emit always fires (bloc `_emitted` flag), even at default 0.8.
        await cubit.load();
        await cubit.setBrightness(0.3);
      },
      expect: () => [0.8, 0.3],
      verify: (_) async {
        expect(await settings.loadBrightness(), 0.3);
        expect(client.sets.last, 0.3);
      },
    );

    blocTest<DisplayBrightnessCubit, double>(
      'setBrightness persists without DDC when unsupported',
      setUp: () {
        client.supported = false;
      },
      build: build,
      act: (cubit) async {
        await cubit.load();
        await cubit.setBrightness(0.25);
      },
      expect: () => [0.8, 0.25],
      verify: (_) async {
        expect(await settings.loadBrightness(), 0.25);
        expect(client.sets, isEmpty);
      },
    );

    blocTest<DisplayBrightnessCubit, double>(
      'setBrightness floors at kMinDisplayBrightness (not fully black)',
      setUp: () {
        client.supported = false;
      },
      build: build,
      act: (cubit) async {
        await cubit.load();
        await cubit.setBrightness(0);
      },
      expect: () => [0.8, kMinDisplayBrightness],
      verify: (_) async {
        expect(await settings.loadBrightness(), kMinDisplayBrightness);
      },
    );
  });
}
