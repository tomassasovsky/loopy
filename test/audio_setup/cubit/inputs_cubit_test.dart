import 'package:flutter_test/flutter_test.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;
  late InputsCubit cubit;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    cubit = InputsCubit(settings: settings);
  });

  tearDown(() async => cubit.close());

  test('an unnamed input has no name of its own', () {
    expect(cubit.state.nameOf(0), isEmpty);
    expect(cubit.state.namedCount, 0);
  });

  test('naming an input persists it and reloads', () async {
    await cubit.rename(1, '  mic  ');

    // Trimmed, counted, and readable back.
    expect(cubit.state.nameOf(1), 'mic');
    expect(cubit.state.namedCount, 1);
    expect(await settings.loadInputName(1), 'mic');

    final reloaded = InputsCubit(settings: settings);
    addTearDown(reloaded.close);
    await reloaded.load();
    expect(reloaded.state.nameOf(1), 'mic');
  });

  test('clearing a name gives the input its ordinal back', () async {
    await cubit.rename(0, 'guitar');
    await cubit.rename(0, '');

    expect(cubit.state.nameOf(0), isEmpty);
    expect(cubit.state.namedCount, 0);
  });

  test('a name outside the input range is ignored', () async {
    await cubit.rename(-1, 'nowhere');
    await cubit.rename(InputsState.maxInputs, 'nowhere');

    expect(cubit.state.names.any((name) => name.isNotEmpty), isFalse);
  });

  test('names outlive the device that had those sockets', () async {
    // Kept per socket index up to the engine ceiling, not per current device:
    // swapping interfaces and back must not lose them.
    await cubit.rename(7, 'talkback');
    final reloaded = InputsCubit(settings: settings, inputCount: 2);
    addTearDown(reloaded.close);
    await reloaded.load();

    // A 2-input device shows two, and the stored name is still there.
    expect(reloaded.state.names, hasLength(2));
    expect(await settings.loadInputName(7), 'talkback');
  });
}
