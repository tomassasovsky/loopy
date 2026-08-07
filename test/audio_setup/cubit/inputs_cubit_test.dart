import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('InputsCubit', () {
    test('every socket starts unnamed', () {
      final cubit = InputsCubit(settings: settings);
      addTearDown(cubit.close);
      expect(cubit.state.names.length, InputsState.maxInputs);
      expect(cubit.state.names.every((name) => name.isEmpty), isTrue);
      expect(cubit.state.namedCount, 0);
      expect(cubit.state.isNamed(0), isFalse);
    });

    blocTest<InputsCubit, InputsState>(
      'rename trims, persists, and counts',
      build: () => InputsCubit(settings: settings),
      act: (cubit) => cubit.rename(1, '  mic  '),
      expect: () => [
        isA<InputsState>()
            .having((s) => s.names[1], 'name', 'mic')
            .having((s) => s.namedCount, 'named', 1),
      ],
      verify: (_) async => expect(await settings.loadInputName(1), 'mic'),
    );

    blocTest<InputsCubit, InputsState>(
      'load restores persisted names',
      setUp: () => settings.saveInputName(0, 'guitar'),
      build: () => InputsCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<InputsState>().having((s) => s.names[0], 'name', 'guitar'),
      ],
    );

    blocTest<InputsCubit, InputsState>(
      'rename during load keeps the renamed value',
      setUp: () async {
        await settings.saveInputName(0, 'guitar');
        await settings.saveInputName(3, 'keys');
      },
      build: () => InputsCubit(settings: settings),
      act: (cubit) async {
        final loadFuture = cubit.load();
        await cubit.rename(0, 'DI');
        await loadFuture;
      },
      expect: () => [
        isA<InputsState>().having((s) => s.names[0], 'name', 'DI'),
        // The restore still lands — MERGED, not dropped. Abandoning it would
        // lose every OTHER socket's persisted name for the session, since
        // load() is memoised and never runs again.
        isA<InputsState>()
            .having((s) => s.names[0], 'renamed socket', 'DI')
            .having((s) => s.names[3], 'untouched socket', 'keys'),
      ],
      verify: (_) async => expect(await settings.loadInputName(0), 'DI'),
    );

    blocTest<InputsCubit, InputsState>(
      'emptying a name un-names the socket and FORGETS the key',
      // The rename sheet has no Clear button — a backspace and Save — so
      // emptying the field is how an input is un-named. Removed rather than
      // stored as `''`: an input's fallback is not a name it was given.
      setUp: () => settings.saveInputName(0, 'guitar'),
      build: () => InputsCubit(settings: settings),
      act: (cubit) async {
        await cubit.load();
        await cubit.rename(0, '   ');
      },
      expect: () => [
        isA<InputsState>().having((s) => s.names[0], 'name', 'guitar'),
        isA<InputsState>()
            .having((s) => s.names[0], 'name', isEmpty)
            .having((s) => s.namedCount, 'named', 0),
      ],
      verify: (_) async => expect(await settings.loadInputName(0), isNull),
    );

    blocTest<InputsCubit, InputsState>(
      'renaming to the same name emits nothing',
      setUp: () => settings.saveInputName(2, 'keys'),
      build: () => InputsCubit(settings: settings),
      act: (cubit) async {
        await cubit.load();
        await cubit.rename(2, 'keys');
      },
      expect: () => [
        isA<InputsState>().having((s) => s.names[2], 'name', 'keys'),
      ],
    );

    blocTest<InputsCubit, InputsState>(
      'a socket past the engine ceiling is refused, not appended',
      build: () => InputsCubit(settings: settings),
      act: (cubit) => cubit.rename(InputsState.maxInputs, 'nope'),
      expect: () => <InputsState>[],
      verify: (cubit) =>
          expect(cubit.state.names.length, InputsState.maxInputs),
    );

    test('names outlive the device that had those sockets', () async {
      // Kept per SOCKET, up to the engine's own input ceiling — not per
      // current device. Swapping to a two-input interface and back must not
      // lose what input 6 was called.
      final cubit = InputsCubit(settings: settings);
      addTearDown(cubit.close);
      await cubit.rename(5, 'talkback');

      final reloaded = InputsCubit(settings: settings);
      addTearDown(reloaded.close);
      await reloaded.load();
      expect(reloaded.state.names[5], 'talkback');
    });

    test('load is idempotent — a second call does not re-walk the sockets', () {
      final cubit = InputsCubit(settings: settings);
      addTearDown(cubit.close);
      expect(cubit.load(), same(cubit.load()));
    });
  });
}
