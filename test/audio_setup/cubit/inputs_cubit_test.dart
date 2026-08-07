import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The engine with an interface open. The device NAME is the key the names are
/// stored against, so a test that never opens one can never store a name.
const _scarlett = LooperState(
  status: EngineStatus(
    isConnected: true,
    deviceName: 'Scarlett 18i20',
    sampleRate: 48000,
    inputChannels: 18,
  ),
);

const _builtIn = LooperState(
  status: EngineStatus(
    isConnected: true,
    deviceName: 'Built-in audio',
    sampleRate: 48000,
    inputChannels: 2,
  ),
);

void main() {
  late SettingsRepository settings;
  late _MockLooperRepository repository;
  late StreamController<LooperState> engine;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    engine = StreamController<LooperState>.broadcast();
    addTearDown(engine.close);
    when(() => repository.looperState).thenAnswer((_) => engine.stream);
    when(() => repository.state).thenReturn(_scarlett);
  });

  InputsCubit build() {
    final cubit = InputsCubit(settings: settings, repository: repository);
    addTearDown(cubit.close);
    return cubit;
  }

  /// Lets the constructor's own device read land before the test asserts.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('InputsCubit', () {
    test('adopts the device the engine already has open', () async {
      final cubit = build();
      await settle();
      expect(cubit.state.device, 'Scarlett 18i20');
      expect(cubit.state.names, isEmpty);
      expect(cubit.state.namedCount(18), 0);
      expect(cubit.state.isNamed(0), isFalse);
    });

    test('rename trims, persists against the DEVICE, and counts', () async {
      final cubit = build();
      await settle();

      await cubit.rename(1, '  mic  ');
      expect(cubit.state.nameOf(1), 'mic');
      expect(cubit.state.namedCount(18), 1);
      expect(
        await settings.loadInputName(device: 'Scarlett 18i20', input: 1),
        'mic',
      );
      // And nothing was written against any other device.
      expect(
        await settings.loadInputName(device: 'Built-in audio', input: 1),
        isNull,
      );
    });

    test('a different interface has its own names', () async {
      // The whole reason the key carries the device: input 1 on a Scarlett and
      // input 1 on the built-in pair are different jacks with different things
      // plugged into them.
      final cubit = build();
      await settle();
      await cubit.rename(0, 'guitar');

      engine.add(_builtIn);
      await settle();
      expect(cubit.state.device, 'Built-in audio');
      expect(cubit.state.nameOf(0), isEmpty);

      await cubit.rename(0, 'laptop mic');
      engine.add(_scarlett);
      await settle();
      // Swapping back finds the Scarlett's own name, untouched.
      expect(cubit.state.nameOf(0), 'guitar');
    });

    test('names survive past the engine lane ceiling', () async {
      // Socket 12 of an 18-in rig is recordable, so it is nameable — the cap
      // this used to have was a misreading of LE_MAX_INPUTS (#558).
      final cubit = build();
      await settle();

      await cubit.rename(11, 'talkback');
      expect(cubit.state.nameOf(11), 'talkback');

      final reloaded = build();
      await settle();
      expect(reloaded.state.nameOf(11), 'talkback');
    });

    test('emptying a name un-names the socket and FORGETS the key', () async {
      // The rename sheet has no Clear button — a backspace and Save — so
      // emptying the field is how an input is un-named. Removed rather than
      // stored as an empty string: an input's fallback is not a name.
      final cubit = build();
      await settle();
      await cubit.rename(0, 'guitar');

      await cubit.rename(0, '   ');
      expect(cubit.state.isNamed(0), isFalse);
      expect(cubit.state.namedCount(18), 0);
      expect(
        await settings.loadInputName(device: 'Scarlett 18i20', input: 0),
        isNull,
      );
    });

    test('renaming to the same name changes nothing', () async {
      final cubit = build();
      await settle();
      await cubit.rename(2, 'keys');

      final before = cubit.state;
      await cubit.rename(2, 'keys');
      expect(cubit.state, same(before));
    });

    test('a rename with no device open is refused', () async {
      // Nothing to key it to. Stored against an empty device it would be a
      // name that reappears on whatever opens next.
      when(() => repository.state).thenReturn(const LooperState());
      final cubit = build();
      await settle();

      await cubit.rename(0, 'guitar');
      expect(cubit.state.names, isEmpty);
    });

    test('a reopen does not blank the names it is between', () async {
      // The engine reports no device for the length of a device change. The
      // outgoing names are kept until the incoming device names itself —
      // clearing would blank every chip mid-reopen.
      final cubit = build();
      await settle();
      await cubit.rename(0, 'guitar');

      engine.add(const LooperState());
      await settle();
      expect(cubit.state.nameOf(0), 'guitar');
      expect(cubit.state.device, 'Scarlett 18i20');
    });

    test('a rename racing the device read is MERGED, not dropped', () async {
      // The restore walks the sockets one await at a time. Abandoning it on a
      // race would lose every OTHER socket's persisted name.
      await settings.saveInputName(
        device: 'Scarlett 18i20',
        input: 0,
        name: 'guitar',
      );
      await settings.saveInputName(
        device: 'Scarlett 18i20',
        input: 3,
        name: 'keys',
      );

      final cubit = build();
      await cubit.rename(0, 'DI');
      await settle();

      expect(cubit.state.nameOf(0), 'DI', reason: 'the rename wins');
      expect(cubit.state.nameOf(3), 'keys', reason: 'the restore still lands');
    });
  });

  group('InputsState', () {
    test('namedCount counts only the sockets the face shows', () {
      // A name kept for a socket THIS device has not got would make the Inputs
      // row disagree with the list under it.
      const state = InputsState(
        device: 'Built-in audio',
        names: {0: 'guitar', 6: 'talkback'},
      );
      expect(state.namedCount(2), 1);
      expect(state.namedCount(8), 2);
    });
  });
}
